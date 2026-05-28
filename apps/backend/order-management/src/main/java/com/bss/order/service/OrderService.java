package com.bss.order.service;

import com.bss.order.dto.CreateOrderRequest;
import com.bss.order.dto.OrderDto;
import com.bss.order.exception.NotFoundException;
import com.bss.order.model.EventOutbox;
import com.bss.order.model.OrderItem;
import com.bss.order.model.ProductOrder;
import com.bss.order.repository.EventOutboxRepository;
import com.bss.order.repository.ProductOrderRepository;
import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.ObjectMapper;
import org.springframework.data.domain.Page;
import org.springframework.data.domain.PageRequest;
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

    public OrderService(ProductOrderRepository orders,
                        EventOutboxRepository outbox,
                        ObjectMapper json) {
        this.orders = orders;
        this.outbox = outbox;
        this.json = json;
    }

    public OrderDto create(CreateOrderRequest req) {
        var order = new ProductOrder();
        order.setCustomerId(req.customerId());
        order.setCategory(req.category());
        order.setDescription(req.description());

        for (var item : req.items()) {
            var oi = new OrderItem();
            oi.setProductOfferingId(item.productOfferingId());
            oi.setProductOfferingName(item.productOfferingName() != null
                    ? item.productOfferingName() : "Offering");
            oi.setQuantity(item.quantity());
            oi.setUnitPrice(item.unitPrice());
            order.addItem(oi);
        }
        order.recomputeTotal();

        // Single-step orders auto-complete. Real BSS would orchestrate provisioning.
        order.setState(ProductOrder.State.Completed);
        order.setCompletedAt(Instant.now());

        var saved = orders.save(order);

        // Outbox row, same TX as the order.
        outbox.save(EventOutbox.of(
                "ProductOrder", saved.getId(), "OrderCompleted",
                payloadJson(Map.of(
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
        var pageable = PageRequest.of(offset / Math.max(limit, 1), limit,
                Sort.by("createdAt").descending());
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
