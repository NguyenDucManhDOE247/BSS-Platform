package com.bss.billing.repository;

import com.bss.billing.dto.InvoiceSummaryDto;
import com.bss.billing.model.Invoice;
import org.springframework.data.domain.Page;
import org.springframework.data.domain.Pageable;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Query;

import java.util.UUID;

public interface InvoiceRepository extends JpaRepository<Invoice, UUID> {
    Page<Invoice> findByBillingAccount_CustomerId(UUID customerId, Pageable pageable);
    Page<Invoice> findByBillingAccount_Id(UUID billingAccountId, Pageable pageable);

    /** Giai đoạn 9 (ADR-008 quyết định 5): hóa đơn của chính khách đang đăng nhập. */
    Page<Invoice> findByBillingAccount_OwnerSub(String ownerSub, Pageable pageable);

    /**
     * Giai đoạn 9 việc 5 — doanh thu cho Dashboard: tính bằng 1 câu SQL tổng hợp ở DB, không kéo mọi
     * hóa đơn về service để cộng. Chỉ có 1 loại tiền (VND) nên chưa cần group by currency.
     */
    @Query("select new com.bss.billing.dto.InvoiceSummaryDto(count(i), coalesce(sum(i.amount), 0), "
            + "coalesce(sum(i.taxAmount), 0), 'VND') from Invoice i")
    InvoiceSummaryDto summarize();
}
