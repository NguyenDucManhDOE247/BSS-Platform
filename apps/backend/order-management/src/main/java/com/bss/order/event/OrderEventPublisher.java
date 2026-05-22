package com.bss.order.event;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Component;
import software.amazon.awssdk.services.eventbridge.EventBridgeClient;
import software.amazon.awssdk.services.eventbridge.model.PutEventsRequest;
import software.amazon.awssdk.services.eventbridge.model.PutEventsRequestEntry;

import java.time.Instant;

@Component
public class OrderEventPublisher {

    private final EventBridgeClient client;
    private final String eventBusName;

    public OrderEventPublisher(EventBridgeClient client,
                               @Value("${aws.eventbridge.bus-name}") String eventBusName) {
        this.client = client;
        this.eventBusName = eventBusName;
    }

    public void publishOrderCompleted(String orderId, String customerId, String amount) {
        var entry = PutEventsRequestEntry.builder()
                .eventBusName(eventBusName)
                .source("bss.order")
                .detailType("OrderCompleted")
                .time(Instant.now())
                .detail(String.format(
                        "{\"orderId\":\"%s\",\"customerId\":\"%s\",\"amount\":\"%s\"}",
                        orderId, customerId, amount))
                .build();

        client.putEvents(PutEventsRequest.builder().entries(entry).build());
    }
}
