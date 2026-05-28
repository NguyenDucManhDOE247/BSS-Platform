package com.bss.billing.dto;

import com.bss.billing.model.BillingAccount.PaymentMethod;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;

import java.util.UUID;

public record CreateAccountRequest(
        @NotNull UUID customerId,
        @NotBlank String name,
        PaymentMethod paymentMethod,
        String currency
) {}
