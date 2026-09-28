package com.bss.order.dto;

import jakarta.validation.Valid;
import jakarta.validation.constraints.NotEmpty;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Positive;

import java.util.List;
import java.util.UUID;

/**
 * @param customerId Giai đoạn 9 (ADR-008): khi BẬT auth, trường này bị BỎ QUA — customerId lấy từ
 *                   hồ sơ của chính người đăng nhập ({@code GET /customer/me}); gửi id người khác cũng
 *                   vô ích. Chỉ còn dùng khi auth tắt (dev/staging/prod cho tới GĐ9 việc 7), lúc đó
 *                   service vẫn bắt buộc có. Deprecated — xóa cùng công tắc {@code bss.auth.enabled}.
 */
public record CreateOrderRequest(
        UUID customerId,
        String category,
        String description,
        @NotEmpty @Valid List<Item> items
) {
    /**
     * B-13 fix: no {@code unitPrice} / {@code productOfferingName} here anymore. Both used to
     * be taken verbatim from the request body — i.e. the caller could name their own price.
     * order-management now looks both up from product-catalog by {@code productOfferingId}
     * (see {@link com.bss.order.client.ProductCatalogClient}), which is the only place prices
     * are allowed to come from.
     */
    public record Item(
            @NotNull UUID productOfferingId,
            @Positive int quantity
    ) {}
}
