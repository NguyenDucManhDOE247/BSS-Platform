package com.bss.order.client;

import com.fasterxml.jackson.annotation.JsonIgnoreProperties;

import java.util.UUID;

/**
 * Giai đoạn 9 (ADR-008): phần hồ sơ khách (từ {@code GET /customer/me} của customer-service) mà
 * order-management cần. {@code ignoreUnknown} — cùng lý do như {@link OfferingSnapshot}: customer-
 * service thêm trường mới không được làm gãy order-management.
 */
@JsonIgnoreProperties(ignoreUnknown = true)
public record CustomerSnapshot(UUID id, String status, String email) {

    /** ADR-008 quyết định 3: chỉ khách admin đã duyệt ({@code Active}) mới được đặt hàng. */
    public boolean isActive() {
        return "Active".equals(status);
    }
}
