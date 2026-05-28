package com.bss.order;

import com.bss.order.dto.CreateOrderRequest;
import com.bss.order.repository.EventOutboxRepository;
import com.bss.order.service.OrderService;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.test.mock.mockito.MockBean;
import org.springframework.boot.testcontainers.service.connection.ServiceConnection;
import org.testcontainers.containers.PostgreSQLContainer;
import org.testcontainers.junit.jupiter.Container;
import org.testcontainers.junit.jupiter.Testcontainers;
import software.amazon.awssdk.services.eventbridge.EventBridgeClient;

import java.math.BigDecimal;
import java.util.List;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;

@SpringBootTest
@Testcontainers
class OrderServiceIT {

    @Container
    @ServiceConnection
    static PostgreSQLContainer<?> postgres = new PostgreSQLContainer<>("postgres:15-alpine");

    /** Real EventBridge not available; mock it so the outbox drainer no-ops cleanly. */
    @MockBean EventBridgeClient eventBridgeClient;

    @Autowired OrderService orders;
    @Autowired EventOutboxRepository outbox;

    @Test
    void create_order_writes_aggregate_and_outbox_row_in_same_tx() {
        var req = new CreateOrderRequest(
                UUID.randomUUID(),
                "new",
                "Buy mobile plan",
                List.of(new CreateOrderRequest.Item(
                        UUID.randomUUID(), "Pro 80", 1, new BigDecimal("199000"))));

        var saved = orders.create(req);

        assertThat(saved.state().name()).isEqualTo("Completed");
        assertThat(saved.totalAmount()).isEqualByComparingTo("199000");

        // Exactly one OrderCompleted outbox row, not yet published.
        var pending = outbox.findUnpublished(org.springframework.data.domain.PageRequest.of(0, 10));
        assertThat(pending).hasSize(1);
        assertThat(pending.get(0).getEventType()).isEqualTo("OrderCompleted");
        assertThat(pending.get(0).getAggregateId()).isEqualTo(saved.id());
        assertThat(pending.get(0).getPublishedAt()).isNull();
    }
}
