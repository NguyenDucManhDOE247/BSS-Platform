package com.bss.billing.dto;

import com.bss.billing.model.BillingAccount;
import com.bss.billing.model.BillingAccount.PaymentMethod;
import com.bss.billing.model.BillingAccount.State;

import java.time.Instant;
import java.util.UUID;

public record BillingAccountDto(
        UUID id,
        UUID customerId,
        String name,
        State state,
        PaymentMethod paymentMethod,
        String currency,
        Instant createdAt
) {
    public static BillingAccountDto from(BillingAccount a) {
        return new BillingAccountDto(
                a.getId(), a.getCustomerId(), a.getName(),
                a.getState(), a.getPaymentMethod(), a.getCurrency(),
                a.getCreatedAt());
    }
}
