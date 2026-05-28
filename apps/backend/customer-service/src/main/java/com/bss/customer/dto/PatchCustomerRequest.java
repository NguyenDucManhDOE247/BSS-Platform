package com.bss.customer.dto;

import com.bss.customer.model.Customer.CustomerStatus;
import jakarta.validation.constraints.Email;

/**
 * Partial update for TMF629. Fields left null are not modified.
 * Matches the semantics of application/merge-patch+json (RFC 7396).
 */
public record PatchCustomerRequest(
        String name,
        @Email String email,
        String phoneNumber,
        CustomerStatus status
) {}
