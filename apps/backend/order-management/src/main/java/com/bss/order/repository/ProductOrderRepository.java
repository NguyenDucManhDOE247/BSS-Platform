package com.bss.order.repository;

import com.bss.order.model.ProductOrder;
import org.springframework.data.domain.Page;
import org.springframework.data.domain.Pageable;
import org.springframework.data.jpa.repository.JpaRepository;

import java.util.UUID;

public interface ProductOrderRepository extends JpaRepository<ProductOrder, UUID> {
    Page<ProductOrder> findByCustomerId(UUID customerId, Pageable pageable);
}
