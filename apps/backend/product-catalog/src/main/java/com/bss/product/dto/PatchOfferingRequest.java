package com.bss.product.dto;

import com.bss.product.model.LifecycleStatus;
import jakarta.validation.constraints.DecimalMin;

import java.math.BigDecimal;
import java.time.Instant;

/**
 * Giai đoạn 9 việc 3b — admin sửa gói cước ({@code PATCH}, merge-patch: trường null = giữ nguyên).
 *
 * <p>"Ngừng bán" = {@code lifecycleStatus: "Retired"} thay vì xóa: đơn hàng cũ vẫn tham chiếu được
 * id gói, còn giá của đơn cũ không đổi vì order-management lưu giá TẠI THỜI ĐIỂM MUA (B-13).
 */
public record PatchOfferingRequest(
        String name,
        String description,
        @DecimalMin("0.0") BigDecimal priceAmount,
        LifecycleStatus lifecycleStatus,
        Instant validForStart,
        Instant validForEnd
) {}
