package com.bss.order.client;

import com.fasterxml.jackson.annotation.JsonIgnoreProperties;

import java.math.BigDecimal;
import java.util.UUID;

/**
 * Slice of product-catalog's {@code ProductOfferingDto} that order-management actually needs.
 *
 * {@code @JsonIgnoreProperties(ignoreUnknown = true)} matters here: product-catalog's real
 * response has more fields (description, categoryId, bundle, ...) and will grow more over
 * time. Without this annotation, Jackson's default "fail on unknown property" would break
 * order-management every time product-catalog adds a field — exactly the kind of tight
 * coupling CLAUDE.md's "backward-compatible only" contract rule warns about.
 */
@JsonIgnoreProperties(ignoreUnknown = true)
public record OfferingSnapshot(
        UUID id,
        String name,
        String lifecycleStatus,
        BigDecimal priceAmount,
        String priceCurrency
) {
    /** TMF620 statuses considered sellable. Anything else (InStudy, Retired, ...) can't be ordered. */
    public boolean isOrderable() {
        return "Active".equals(lifecycleStatus) || "Launched".equals(lifecycleStatus);
    }
}
