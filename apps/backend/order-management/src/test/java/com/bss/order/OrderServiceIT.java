package com.bss.order;

import com.bss.order.client.OfferingNotOrderableException;
import com.bss.order.client.OfferingSnapshot;
import com.bss.order.client.ProductCatalogClient;
import com.bss.order.client.UnknownOfferingException;
import com.bss.order.dto.CreateOrderRequest;
import com.bss.order.repository.EventOutboxRepository;
import com.bss.order.service.OrderService;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
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
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.Mockito.when;

// B-14: the outbox publisher is disabled here — it isn't what these tests are about, and a
// @MockBean EventBridgeClient returning null would otherwise NPE it every 2 seconds.
@SpringBootTest(properties = "bss.outbox.publisher.enabled=false")
@Testcontainers
class OrderServiceIT {

    @Container
    @ServiceConnection
    static PostgreSQLContainer<?> postgres = new PostgreSQLContainer<>("postgres:15-alpine");

    @MockBean EventBridgeClient eventBridgeClient;
    // B-13: order-management no longer trusts the caller's price — it asks product-catalog.
    // Stub that call instead of standing up a real product-catalog for this test.
    @MockBean ProductCatalogClient catalog;

    @Autowired OrderService orders;
    @Autowired EventOutboxRepository outbox;
    @Autowired ObjectMapper json;

    @Test
    void create_order_fetches_price_from_catalog_and_writes_outbox_row_with_eventId() {
        UUID offeringId = UUID.randomUUID();
        when(catalog.getOffering(offeringId)).thenReturn(
                new OfferingSnapshot(offeringId, "Pro 80", "Active",
                        new BigDecimal("199000"), "VND"));

        var req = new CreateOrderRequest(
                UUID.randomUUID(),
                "new",
                "Buy mobile plan",
                List.of(new CreateOrderRequest.Item(offeringId, 1)));

        var saved = orders.create(req);

        assertThat(saved.state().name()).isEqualTo("Completed");
        // B-13: price came from the catalog stub (199000), NOT from the request (there is no
        // unitPrice field on the request anymore — it wouldn't compile if there were).
        assertThat(saved.totalAmount()).isEqualByComparingTo("199000");
        assertThat(saved.items().get(0).productOfferingName()).isEqualTo("Pro 80");

        var pending = outbox.lockUnpublishedBatch(10);
        assertThat(pending).hasSize(1);
        assertThat(pending.get(0).getEventType()).isEqualTo("OrderCompleted");
        assertThat(pending.get(0).getAggregateId()).isEqualTo(saved.id());
        assertThat(pending.get(0).getPublishedAt()).isNull();

        // B-11: the outbox row's own id must be embedded in the payload as "eventId" — that's
        // the stable dedup key billing-service uses, not the EventBridge envelope id (which
        // doesn't exist yet at this point; it's minted per PutEvents attempt).
        JsonNode payload = readTree(pending.get(0).getPayload());
        assertThat(payload.get("eventId").asText()).isEqualTo(pending.get(0).getId().toString());
    }

    @Test
    void create_order_rejects_offering_that_is_not_orderable() {
        UUID offeringId = UUID.randomUUID();
        when(catalog.getOffering(offeringId)).thenReturn(
                new OfferingSnapshot(offeringId, "Retired plan", "Retired",
                        new BigDecimal("50000"), "VND"));

        var req = new CreateOrderRequest(UUID.randomUUID(), "new", "x",
                List.of(new CreateOrderRequest.Item(offeringId, 1)));

        assertThatThrownBy(() -> orders.create(req))
                .isInstanceOf(OfferingNotOrderableException.class);
    }

    @Test
    void create_order_rejects_unknown_offering() {
        UUID offeringId = UUID.randomUUID();
        when(catalog.getOffering(offeringId)).thenThrow(new UnknownOfferingException(offeringId));

        var req = new CreateOrderRequest(UUID.randomUUID(), "new", "x",
                List.of(new CreateOrderRequest.Item(offeringId, 1)));

        assertThatThrownBy(() -> orders.create(req))
                .isInstanceOf(UnknownOfferingException.class);
    }

    private JsonNode readTree(String s) {
        try {
            return json.readTree(s);
        } catch (Exception e) {
            throw new RuntimeException(e);
        }
    }
}
