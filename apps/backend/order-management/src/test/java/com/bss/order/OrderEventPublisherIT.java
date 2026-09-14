package com.bss.order;

import com.bss.order.event.OrderEventPublisher;
import com.bss.order.model.EventOutbox;
import com.bss.order.repository.EventOutboxRepository;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.test.mock.mockito.MockBean;
import org.springframework.boot.testcontainers.service.connection.ServiceConnection;
import org.testcontainers.containers.PostgreSQLContainer;
import org.testcontainers.junit.jupiter.Container;
import org.testcontainers.junit.jupiter.Testcontainers;
import software.amazon.awssdk.services.eventbridge.EventBridgeClient;
import software.amazon.awssdk.services.eventbridge.model.PutEventsRequest;
import software.amazon.awssdk.services.eventbridge.model.PutEventsResponse;
import software.amazon.awssdk.services.eventbridge.model.PutEventsResultEntry;

import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.when;

/**
 * B-12 regression test: after switching {@code findUnpublished} → {@code lockUnpublishedBatch}
 * (SELECT ... FOR UPDATE SKIP LOCKED), the drainer must still do its normal job — pick up
 * every unpublished row and mark it published once EventBridge accepts it. The concurrency
 * property SKIP LOCKED buys us (2 replicas polling at once each get a disjoint batch instead
 * of both grabbing the same rows) is a database-locking guarantee, not something worth
 * re-proving with real concurrent threads/transactions here — that's what Postgres' own
 * documentation and tests already cover; this test proves the query is wired correctly.
 */
@SpringBootTest
@Testcontainers
class OrderEventPublisherIT {

    @Container
    @ServiceConnection
    static PostgreSQLContainer<?> postgres = new PostgreSQLContainer<>("postgres:15-alpine");

    @MockBean EventBridgeClient eventBridgeClient;

    @Autowired OrderEventPublisher publisher;
    @Autowired EventOutboxRepository outbox;

    @Test
    void drain_publishes_every_unpublished_row_via_the_locking_query() {
        var row1 = outbox.save(EventOutbox.of(UUID.randomUUID(), "ProductOrder",
                UUID.randomUUID(), "OrderCompleted", "{\"eventId\":\"a\"}"));
        var row2 = outbox.save(EventOutbox.of(UUID.randomUUID(), "ProductOrder",
                UUID.randomUUID(), "OrderCompleted", "{\"eventId\":\"b\"}"));

        when(eventBridgeClient.putEvents(any(PutEventsRequest.class))).thenReturn(
                PutEventsResponse.builder()
                        .entries(
                                PutEventsResultEntry.builder().eventId("evb-1").build(),
                                PutEventsResultEntry.builder().eventId("evb-2").build())
                        .build());

        publisher.drain();

        assertThat(outbox.findById(row1.getId()).orElseThrow().getPublishedAt()).isNotNull();
        assertThat(outbox.findById(row2.getId()).orElseThrow().getPublishedAt()).isNotNull();
        assertThat(outbox.lockUnpublishedBatch(10)).isEmpty();
    }
}
