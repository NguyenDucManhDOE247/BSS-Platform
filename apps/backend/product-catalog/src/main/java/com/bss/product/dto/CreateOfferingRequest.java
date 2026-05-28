package com.bss.product.dto;

import com.bss.product.model.ProductOffering.RecurringPeriod;
import jakarta.validation.constraints.DecimalMin;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;

import java.math.BigDecimal;
import java.time.Instant;
import java.util.UUID;

public record CreateOfferingRequest(
        @NotBlank String name,
        String description,
        UUID categoryId,
        UUID specificationId,
        @NotNull @DecimalMin("0.0") BigDecimal priceAmount,
        String priceCurrency,
        RecurringPeriod recurringPeriod,
        Boolean bundle,
        Instant validForStart,
        Instant validForEnd
) {}
