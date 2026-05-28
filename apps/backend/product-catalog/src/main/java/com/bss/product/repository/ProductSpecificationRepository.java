package com.bss.product.repository;

import com.bss.product.model.ProductSpecification;
import org.springframework.data.jpa.repository.JpaRepository;

import java.util.UUID;

public interface ProductSpecificationRepository extends JpaRepository<ProductSpecification, UUID> {
}
