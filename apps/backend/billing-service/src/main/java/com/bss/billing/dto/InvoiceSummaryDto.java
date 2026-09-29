package com.bss.billing.dto;

import java.math.BigDecimal;

/**
 * Giai đoạn 9 việc 5 — tổng hợp hóa đơn cho Dashboard admin-console (chỉ admin).
 *
 * @param totalAmount tổng tiền PHẢI THU đã gồm VAT (= doanh thu hóa đơn đã phát hành).
 * @param totalTax    phần VAT trong đó.
 */
public record InvoiceSummaryDto(long invoiceCount, BigDecimal totalAmount, BigDecimal totalTax, String currency) {}
