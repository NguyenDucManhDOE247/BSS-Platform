package com.bss.billing.listener;

import com.bss.billing.model.ProcessedEvent;
import com.bss.billing.repository.ProcessedEventRepository;
import com.bss.billing.service.BillingService;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.dao.DataIntegrityViolationException;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;
import org.springframework.transaction.annotation.Transactional;
import software.amazon.awssdk.services.sqs.SqsClient;
import software.amazon.awssdk.services.sqs.model.DeleteMessageRequest;
import software.amazon.awssdk.services.sqs.model.Message;
import software.amazon.awssdk.services.sqs.model.ReceiveMessageRequest;

import java.math.BigDecimal;
import java.util.UUID;

/**
 * Consumes OrderCompleted events delivered from EventBridge → SQS.
 *
 * Idempotency: each message carries an EventBridge message ID (or a digest if absent).
 * We INSERT into processed_event before creating the invoice; the unique PK is the dedup key.
 * If a duplicate arrives, the insert throws DataIntegrityViolationException → we skip + ACK.
 *
 * Failure handling: any other exception leaves the message on the queue. After
 * `maxReceiveCount` (set in the SQS RedrivePolicy) it lands in the DLQ.
 */
@Component
public class OrderEventListener {

    private static final Logger log = LoggerFactory.getLogger(OrderEventListener.class);
    private static final ObjectMapper json = new ObjectMapper();

    private final SqsClient sqs;
    private final String queueUrl;
    private final ProcessedEventRepository processed;
    private final BillingService billing;

    public OrderEventListener(SqsClient sqs,
                              @Value("${aws.sqs.queue-url}") String queueUrl,
                              ProcessedEventRepository processed,
                              BillingService billing) {
        this.sqs = sqs;
        this.queueUrl = queueUrl;
        this.processed = processed;
        this.billing = billing;
    }

    @Scheduled(fixedDelay = 5000)
    public void poll() {
        var req = ReceiveMessageRequest.builder()
                .queueUrl(queueUrl)
                .maxNumberOfMessages(10)
                .waitTimeSeconds(10) // long polling — fewer empty receives
                .build();

        for (var msg : sqs.receiveMessage(req).messages()) {
            try {
                handle(msg);
                ack(msg);
            } catch (DuplicateEventException dup) {
                log.info("Duplicate event {} — skipping and acking", dup.getMessage());
                ack(msg);
            } catch (Exception e) {
                log.error("Failed to process message {}: {}", msg.messageId(), e.getMessage(), e);
                // Leave on queue → SQS redelivers → eventually DLQ.
            }
        }
    }

    @Transactional
    void handle(Message msg) throws Exception {
        JsonNode envelope = json.readTree(msg.body());

        // EventBridge → SQS wraps the payload: { id, source, detail-type, detail: {...} }
        String eventId = envelope.has("id") ? envelope.get("id").asText() : msg.messageId();
        String type = envelope.path("detail-type").asText("Unknown");
        JsonNode detail = envelope.has("detail") ? envelope.get("detail") : envelope;

        if ("OrderCompleted".equals(type)) {
            saveDedupKey(eventId, type);
            UUID orderId = UUID.fromString(detail.get("orderId").asText());
            UUID customerId = UUID.fromString(detail.get("customerId").asText());
            BigDecimal amount = new BigDecimal(detail.get("amount").asText());
            String description = "Order " + orderId;
            var invoice = billing.invoiceFromOrder(customerId, orderId, description, amount);
            log.info("Issued invoice {} for order {}", invoice.invoiceNumber(), orderId);
        } else {
            log.info("Ignoring event type: {}", type);
        }
    }

    private void saveDedupKey(String eventId, String type) {
        try {
            processed.save(new ProcessedEvent(eventId, type));
            processed.flush();
        } catch (DataIntegrityViolationException dup) {
            throw new DuplicateEventException(eventId);
        }
    }

    private void ack(Message msg) {
        sqs.deleteMessage(DeleteMessageRequest.builder()
                .queueUrl(queueUrl)
                .receiptHandle(msg.receiptHandle())
                .build());
    }

    private static class DuplicateEventException extends RuntimeException {
        DuplicateEventException(String eventId) { super(eventId); }
    }
}
