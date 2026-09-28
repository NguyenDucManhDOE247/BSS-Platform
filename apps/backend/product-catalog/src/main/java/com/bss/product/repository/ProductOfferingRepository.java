package com.bss.product.repository;

import com.bss.product.model.LifecycleStatus;
import com.bss.product.model.ProductOffering;
import org.springframework.data.jpa.domain.Specification;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.JpaSpecificationExecutor;

import java.util.Set;
import java.util.UUID;

public interface ProductOfferingRepository
        extends JpaRepository<ProductOffering, UUID>, JpaSpecificationExecutor<ProductOffering> {

    /** Giai đoạn 9: trạng thái khách hàng được thấy (gói "đang bán"). */
    Set<LifecycleStatus> ON_SALE = Set.of(LifecycleStatus.Active, LifecycleStatus.Launched);

    /**
     * Lọc theo danh mục + trạng thái; {@code onSaleOnly} = chỉ gói đang bán (khách hàng). Khi
     * {@code onSaleOnly} mà người gọi cố lọc {@code status=Retired}, kết quả là giao của 2 điều kiện
     * → rỗng, không lộ gói đã ngừng bán.
     */
    static Specification<ProductOffering> filter(UUID categoryId, LifecycleStatus status, boolean onSaleOnly) {
        Specification<ProductOffering> spec = Specification.where(null);
        if (categoryId != null) {
            spec = spec.and((r, q, cb) -> cb.equal(r.get("categoryId"), categoryId));
        }
        if (status != null) {
            spec = spec.and((r, q, cb) -> cb.equal(r.get("lifecycleStatus"), status));
        }
        if (onSaleOnly) {
            spec = spec.and((r, q, cb) -> r.get("lifecycleStatus").in(ON_SALE));
        }
        return spec;
    }
}
