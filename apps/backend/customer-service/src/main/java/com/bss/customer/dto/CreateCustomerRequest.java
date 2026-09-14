package com.bss.customer.dto;

import jakarta.validation.constraints.Email;
import jakarta.validation.constraints.NotBlank;

/**
 * B-15 fix (mass assignment): {@code POST /customer} used to bind the request body straight
 * onto the {@code Customer} JPA entity. That entity exposes a public {@code setStatus(...)},
 * so any caller could create a customer that starts life as {@code Active} (or even
 * {@code Terminated}) instead of going through the intended {@code Initialized → Validated →
 * Active} lifecycle — and any future field added to the entity for internal bookkeeping would
 * automatically become client-settable too, with no code change required to expose it.
 *
 * <p>A request DTO only lists the fields a caller is actually allowed to set on creation.
 * {@code status} always starts at {@code Initialized} (the entity's default); it can only be
 * moved forward afterwards via {@code PATCH} ({@link PatchCustomerRequest}).
 */
public record CreateCustomerRequest(
        @NotBlank String name,
        @NotBlank @Email String email,
        String phoneNumber
) {}
