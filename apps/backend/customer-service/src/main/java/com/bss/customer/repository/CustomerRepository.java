package com.bss.customer.repository;

import com.bss.customer.model.Customer;
import com.bss.customer.model.Customer.CustomerStatus;
import org.springframework.data.jpa.domain.Specification;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.JpaSpecificationExecutor;

import java.util.Locale;
import java.util.Optional;
import java.util.UUID;

public interface CustomerRepository extends JpaRepository<Customer, UUID>, JpaSpecificationExecutor<Customer> {

    Optional<Customer> findByEmail(String email);

    Optional<Customer> findByKeycloakUserId(String keycloakUserId);

    /**
     * Giai đoạn 9 việc 3 — bộ lọc cho admin-console: {@code status} (vd. "Initialized" = chờ duyệt)
     * và {@code q} (tìm theo tên HOẶC email, không phân biệt hoa thường). Tham số null = bỏ qua.
     *
     * <p>Dùng Specification thay vì 1 câu {@code @Query} với {@code (:q is null or ...)}: với
     * Postgres, tham số null đứng trong {@code lower(concat('%', :q, '%'))} có thể lỗi "could not
     * determine data type of parameter" — Specification chỉ thêm điều kiện khi tham số có giá trị.
     */
    static Specification<Customer> filter(CustomerStatus status, String q) {
        Specification<Customer> spec = Specification.where(null);
        if (status != null) {
            spec = spec.and((root, query, cb) -> cb.equal(root.get("status"), status));
        }
        if (q != null && !q.isBlank()) {
            String like = "%" + q.trim().toLowerCase(Locale.ROOT) + "%";
            spec = spec.and((root, query, cb) -> cb.or(
                    cb.like(cb.lower(root.get("name")), like),
                    cb.like(cb.lower(root.get("email")), like)));
        }
        return spec;
    }
}
