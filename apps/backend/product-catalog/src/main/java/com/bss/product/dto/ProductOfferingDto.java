package com.bss.product.dto;

import com.bss.product.model.LifecycleStatus;
import com.bss.product.model.ProductOffering;
import com.bss.product.model.ProductOffering.RecurringPeriod;

import java.math.BigDecimal;
import java.time.Instant;
import java.util.UUID;

public record ProductOfferingDto(
        UUID id,
        String name,
        String description,
        UUID categoryId,
        UUID specificationId,
        LifecycleStatus lifecycleStatus,
        boolean bundle,
        BigDecimal priceAmount,
        String priceCurrency,
        RecurringPeriod recurringPeriod,
        Instant validForStart,
        Instant validForEnd
) {
    public static ProductOfferingDto from(ProductOffering o) {
        return new ProductOfferingDto(
                o.getId(),
                o.getName(),
                o.getDescription(),
                o.getCategoryId(),
                o.getSpecificationId(),
                o.getLifecycleStatus(),
                o.isBundle(),
                o.getPriceAmount(),
                o.getPriceCurrency(),
                o.getRecurringPeriod(),
                o.getValidForStart(),
                o.getValidForEnd()
        );
    }
}
