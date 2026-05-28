package com.bss.product.repository;

import com.bss.product.model.LifecycleStatus;
import com.bss.product.model.ProductOffering;
import org.springframework.data.domain.Page;
import org.springframework.data.domain.Pageable;
import org.springframework.data.jpa.repository.JpaRepository;

import java.util.UUID;

public interface ProductOfferingRepository extends JpaRepository<ProductOffering, UUID> {

    Page<ProductOffering> findByCategoryId(UUID categoryId, Pageable pageable);

    Page<ProductOffering> findByLifecycleStatus(LifecycleStatus status, Pageable pageable);

    Page<ProductOffering> findByCategoryIdAndLifecycleStatus(UUID categoryId,
                                                             LifecycleStatus status,
                                                             Pageable pageable);
}
