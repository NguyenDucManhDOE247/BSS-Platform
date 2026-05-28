package com.bss.order.dto;

import com.bss.order.model.ProductOrder;
import com.bss.order.model.ProductOrder.State;

import java.math.BigDecimal;
import java.time.Instant;
import java.util.List;
import java.util.UUID;

public record OrderDto(
        UUID id,
        UUID customerId,
        State state,
        String category,
        String description,
        BigDecimal totalAmount,
        String currency,
        Instant completedAt,
        Instant createdAt,
        List<Item> items
) {
    public record Item(UUID id, UUID productOfferingId, String productOfferingName,
                       int quantity, BigDecimal unitPrice) {}

    public static OrderDto from(ProductOrder o) {
        var items = o.getItems().stream()
                .map(i -> new Item(i.getId(), i.getProductOfferingId(),
                        i.getProductOfferingName(), i.getQuantity(), i.getUnitPrice()))
                .toList();
        return new OrderDto(
                o.getId(), o.getCustomerId(), o.getState(),
                o.getCategory(), o.getDescription(),
                o.getTotalAmount(), o.getCurrency(),
                o.getCompletedAt(), o.getCreatedAt(), items);
    }
}
