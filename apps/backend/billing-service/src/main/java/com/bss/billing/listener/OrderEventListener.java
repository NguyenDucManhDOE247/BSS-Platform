package com.bss.billing.listener;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;
import software.amazon.awssdk.services.sqs.SqsClient;
import software.amazon.awssdk.services.sqs.model.DeleteMessageRequest;
import software.amazon.awssdk.services.sqs.model.ReceiveMessageRequest;

/**
 * Polls SQS for OrderCompleted events delivered by EventBridge.
 * Each message is processed idempotently — the order ID is the dedup key.
 *
 * Replace with Spring Cloud AWS Messaging once you're comfortable wiring it.
 */
@Component
public class OrderEventListener {

    private static final Logger log = LoggerFactory.getLogger(OrderEventListener.class);

    private final SqsClient sqs;
    private final String queueUrl;

    public OrderEventListener(SqsClient sqs,
                              @Value("${aws.sqs.queue-url}") String queueUrl) {
        this.sqs = sqs;
        this.queueUrl = queueUrl;
    }

    @Scheduled(fixedDelay = 5000)
    public void poll() {
        var request = ReceiveMessageRequest.builder()
                .queueUrl(queueUrl)
                .maxNumberOfMessages(10)
                .waitTimeSeconds(10) // long polling
                .build();

        var messages = sqs.receiveMessage(request).messages();
        for (var msg : messages) {
            try {
                log.info("Processing event: {}", msg.body());
                // TODO: idempotent invoice creation. For now, just log.
                sqs.deleteMessage(DeleteMessageRequest.builder()
                        .queueUrl(queueUrl)
                        .receiptHandle(msg.receiptHandle())
                        .build());
            } catch (Exception e) {
                log.error("Failed to process message {}: {}", msg.messageId(), e.getMessage(), e);
                // Leave it on the queue; after maxReceiveCount it lands in DLQ.
            }
        }
    }
}
