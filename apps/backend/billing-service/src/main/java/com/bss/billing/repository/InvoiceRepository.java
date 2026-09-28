package com.bss.billing.repository;

import com.bss.billing.model.Invoice;
import org.springframework.data.domain.Page;
import org.springframework.data.domain.Pageable;
import org.springframework.data.jpa.repository.JpaRepository;

import java.util.UUID;

public interface InvoiceRepository extends JpaRepository<Invoice, UUID> {
    Page<Invoice> findByBillingAccount_CustomerId(UUID customerId, Pageable pageable);
    Page<Invoice> findByBillingAccount_Id(UUID billingAccountId, Pageable pageable);

    /** Giai đoạn 9 (ADR-008 quyết định 5): hóa đơn của chính khách đang đăng nhập. */
    Page<Invoice> findByBillingAccount_OwnerSub(String ownerSub, Pageable pageable);
}
