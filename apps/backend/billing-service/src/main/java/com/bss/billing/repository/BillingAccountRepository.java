package com.bss.billing.repository;

import com.bss.billing.model.BillingAccount;
import org.springframework.data.domain.Page;
import org.springframework.data.domain.Pageable;
import org.springframework.data.jpa.repository.JpaRepository;

import java.util.Optional;
import java.util.UUID;

public interface BillingAccountRepository extends JpaRepository<BillingAccount, UUID> {
    Optional<BillingAccount> findByCustomerId(UUID customerId);

    /** Giai đoạn 9 (ADR-008 quyết định 5): account của chính khách đang đăng nhập. */
    Page<BillingAccount> findByOwnerSub(String ownerSub, Pageable pageable);
}
