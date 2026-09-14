package com.bss.order.client;

import java.util.UUID;

/** The offering exists but its TMF620 lifecycle status means it can't be sold right now. */
public class OfferingNotOrderableException extends RuntimeException {
    public OfferingNotOrderableException(UUID offeringId, String lifecycleStatus) {
        super("Product offering %s is not orderable (status=%s)".formatted(offeringId, lifecycleStatus));
    }
}
