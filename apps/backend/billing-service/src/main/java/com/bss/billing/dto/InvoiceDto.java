package com.bss.billing.dto;

import com.bss.billing.model.Invoice;
import com.bss.billing.model.Invoice.State;

import java.math.BigDecimal;
import java.time.Instant;
import java.time.LocalDate;
import java.util.List;
import java.util.UUID;

public record InvoiceDto(
        UUID id,
        UUID billingAccountId,
        String invoiceNumber,
        State state,
        BigDecimal amount,
        BigDecimal taxAmount,
        String currency,
        LocalDate invoiceDate,
        LocalDate dueDate,
        Instant paidAt,
        List<Item> items
) {
    public record Item(UUID id, String description, UUID sourceOrderId,
                       int quantity, BigDecimal unitPrice, BigDecimal amount) {}

    public static InvoiceDto from(Invoice inv) {
        var items = inv.getItems().stream()
                .map(i -> new Item(i.getId(), i.getDescription(), i.getSourceOrderId(),
                        i.getQuantity(), i.getUnitPrice(), i.getAmount()))
                .toList();
        return new InvoiceDto(
                inv.getId(),
                inv.getBillingAccount().getId(),
                inv.getInvoiceNumber(),
                inv.getState(),
                inv.getAmount(),
                inv.getTaxAmount(),
                inv.getCurrency(),
                inv.getInvoiceDate(),
                inv.getDueDate(),
                inv.getPaidAt(),
                items);
    }
}
