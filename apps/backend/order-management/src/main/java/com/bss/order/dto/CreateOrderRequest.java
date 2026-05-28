package com.bss.order.dto;

import jakarta.validation.Valid;
import jakarta.validation.constraints.NotEmpty;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Positive;

import java.math.BigDecimal;
import java.util.List;
import java.util.UUID;

public record CreateOrderRequest(
        @NotNull UUID customerId,
        String category,
        String description,
        @NotEmpty @Valid List<Item> items
) {
    public record Item(
            @NotNull UUID productOfferingId,
            String productOfferingName,
            @Positive int quantity,
            @NotNull BigDecimal unitPrice
    ) {}
}
