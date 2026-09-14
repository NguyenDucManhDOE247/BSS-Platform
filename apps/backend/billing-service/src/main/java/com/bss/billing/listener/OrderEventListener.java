package com.bss.billing.listener;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;
import software.amazon.awssdk.services.sqs.SqsClient;
import software.amazon.awssdk.services.sqs.model.DeleteMessageRequest;
import software.amazon.awssdk.services.sqs.model.Message;
import software.amazon.awssdk.services.sqs.model.ReceiveMessageRequest;

/**
 * Consumes OrderCompleted events delivered from EventBridge → SQS.
 *
 * Idempotency (B-11): each event's dedup key is {@code detail.eventId} — the id
 * order-management's outbox row was given when it was created (see
 * {@code EventOutbox} javadoc in order-management), NOT the EventBridge envelope's own
 * {@code id} field. The envelope id is minted fresh by EventBridge on every PutEvents call,
 * including retries of the very same outbox row, so it cannot be trusted as a dedup key — two
 * different envelope ids can (and did) carry the same logical event, producing two invoices
 * for one order. Falls back to the envelope id only for messages that predate this fix / don't
 * carry eventId, so old messages already in flight don't crash the consumer.
 *
 * Actual dedup insert + invoice creation now happens in {@link OrderCompletedHandler}, a
 * separate bean, so {@code @Transactional} on {@code handle(...)} actually takes effect
 * (see B-10 — that method used to be a self-invoked call on this same class, which Spring's
 * proxy-based transactions never intercept).
 *
 * Failure handling: any other exception leaves the message on the queue. After
 * `maxReceiveCount` (set in the SQS RedrivePolicy) it lands in the DLQ.
 */
@Component
@ConditionalOnProperty(name = "bss.sqs.consumer.enabled", havingValue = "true", matchIfMissing = true)
public class OrderEventListener {

    private static final Logger log = LoggerFactory.getLogger(OrderEventListener.class);
    private static final ObjectMapper json = new ObjectMapper();

    private final SqsClient sqs;
    private final String queueUrl;
    private final OrderCompletedHandler handler;

    public OrderEventListener(SqsClient sqs,
                              @Value("${aws.sqs.queue-url}") String queueUrl,
                              OrderCompletedHandler handler) {
        this.sqs = sqs;
        this.queueUrl = queueUrl;
        this.handler = handler;
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
                dispatch(msg);
                ack(msg);
            } catch (OrderCompletedHandler.DuplicateEventException dup) {
                log.info("Duplicate event {} — skipping and acking", dup.getMessage());
                ack(msg);
            } catch (Exception e) {
                log.error("Failed to process message {}: {}", msg.messageId(), e.getMessage(), e);
                // Leave on queue → SQS redelivers → eventually DLQ.
            }
        }
    }

    private void dispatch(Message msg) throws Exception {
        JsonNode envelope = json.readTree(msg.body());

        // EventBridge → SQS wraps the payload: { id, source, detail-type, detail: {...} }
        String type = envelope.path("detail-type").asText("Unknown");
        JsonNode detail = envelope.has("detail") ? envelope.get("detail") : envelope;

        if (!"OrderCompleted".equals(type)) {
            log.info("Ignoring event type: {}", type);
            return;
        }

        String eventId = detail.hasNonNull("eventId")
                ? detail.get("eventId").asText()
                : envelope.has("id") ? envelope.get("id").asText() : msg.messageId();

        handler.handle(eventId, type, detail);
    }

    private void ack(Message msg) {
        sqs.deleteMessage(DeleteMessageRequest.builder()
                .queueUrl(queueUrl)
                .receiptHandle(msg.receiptHandle())
                .build());
    }
}
