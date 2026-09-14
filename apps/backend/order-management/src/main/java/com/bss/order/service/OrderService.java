package com.bss.order.service;

import com.bss.order.client.OfferingNotOrderableException;
import com.bss.order.client.ProductCatalogClient;
import com.bss.order.dto.CreateOrderRequest;
import com.bss.order.dto.OrderDto;
import com.bss.order.exception.NotFoundException;
import com.bss.order.model.EventOutbox;
import com.bss.order.model.OrderItem;
import com.bss.order.model.ProductOrder;
import com.bss.order.paging.OffsetPageRequest;
import com.bss.order.repository.EventOutboxRepository;
import com.bss.order.repository.ProductOrderRepository;
import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.ObjectMapper;
import org.springframework.data.domain.Page;
import org.springframework.data.domain.Sort;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.time.Instant;
import java.util.Map;
import java.util.UUID;

@Service
@Transactional
public class OrderService {

    private final ProductOrderRepository orders;
    private final EventOutboxRepository outbox;
    private final ObjectMapper json;
    private final ProductCatalogClient catalog;

    public OrderService(ProductOrderRepository orders,
                        EventOutboxRepository outbox,
                        ObjectMapper json,
                        ProductCatalogClient catalog) {
        this.orders = orders;
        this.outbox = outbox;
        this.json = json;
        this.catalog = catalog;
    }

    public OrderDto create(CreateOrderRequest req) {
        var order = new ProductOrder();
        order.setCustomerId(req.customerId());
        order.setCategory(req.category());
        order.setDescription(req.description());

        for (var item : req.items()) {
            // B-13: price + name are authoritative from product-catalog, never from the caller.
            var offering = catalog.getOffering(item.productOfferingId());
            if (!offering.isOrderable()) {
                throw new OfferingNotOrderableException(item.productOfferingId(), offering.lifecycleStatus());
            }
            var oi = new OrderItem();
            oi.setProductOfferingId(offering.id());
            oi.setProductOfferingName(offering.name());
            oi.setQuantity(item.quantity());
            oi.setUnitPrice(offering.priceAmount());
            order.addItem(oi);
        }
        order.recomputeTotal();

        // Single-step orders auto-complete. Real BSS would orchestrate provisioning.
        order.setState(ProductOrder.State.Completed);
        order.setCompletedAt(Instant.now());

        var saved = orders.save(order);

        // B-11: mint the dedup key *before* building the payload, so it can be embedded in the
        // event body itself. billing-service dedups on this id, not on the EventBridge
        // envelope id (which changes on every PutEvents attempt, including retries of this
        // very row) — see EventOutbox javadoc for the full reasoning.
        UUID eventId = UUID.randomUUID();

        // Outbox row, same TX as the order.
        outbox.save(EventOutbox.of(
                eventId,
                "ProductOrder", saved.getId(), "OrderCompleted",
                payloadJson(Map.of(
                        "eventId", eventId.toString(),
                        "orderId", saved.getId().toString(),
                        "customerId", saved.getCustomerId().toString(),
                        "amount", saved.getTotalAmount().toPlainString(),
                        "currency", saved.getCurrency(),
                        "completedAt", saved.getCompletedAt().toString()
                ))));

        return OrderDto.from(saved);
    }

    @Transactional(readOnly = true)
    public OrderDto get(UUID id) {
        return orders.findById(id)
                .map(OrderDto::from)
                .orElseThrow(() -> new NotFoundException("ProductOrder", id.toString()));
    }

    @Transactional(readOnly = true)
    public Page<OrderDto> listForCustomer(UUID customerId, int offset, int limit) {
        var pageable = OffsetPageRequest.of(offset, limit, Sort.by("createdAt").descending());
        return orders.findByCustomerId(customerId, pageable).map(OrderDto::from);
    }

    private String payloadJson(Map<String, Object> data) {
        try {
            return json.writeValueAsString(data);
        } catch (JsonProcessingException e) {
            // Map -> JSON serialization with plain types never fails at runtime.
            throw new IllegalStateException("event payload serialization failed", e);
        }
    }
}
