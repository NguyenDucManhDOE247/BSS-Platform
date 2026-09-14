package com.bss.order.client;

import java.util.UUID;

/** The requested productOfferingId does not exist in product-catalog. */
public class UnknownOfferingException extends RuntimeException {
    public UnknownOfferingException(UUID offeringId) {
        super("Product offering not found: " + offeringId);
    }
}
