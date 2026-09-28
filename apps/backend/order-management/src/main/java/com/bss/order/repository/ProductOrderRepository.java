package com.bss.order.repository;

import com.bss.order.model.ProductOrder;
import org.springframework.data.domain.Page;
import org.springframework.data.domain.Pageable;
import org.springframework.data.jpa.repository.JpaRepository;

import java.util.UUID;

public interface ProductOrderRepository extends JpaRepository<ProductOrder, UUID> {

    Page<ProductOrder> findByCustomerId(UUID customerId, Pageable pageable);

    /** Giai đoạn 9 (ADR-008 quyết định 5): đơn của chính khách đang đăng nhập. */
    Page<ProductOrder> findByOwnerSub(String ownerSub, Pageable pageable);
}
