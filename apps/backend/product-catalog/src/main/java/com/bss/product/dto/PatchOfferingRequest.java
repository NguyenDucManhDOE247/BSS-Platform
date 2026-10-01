package com.bss.product.dto;

import com.bss.product.model.LifecycleStatus;
import jakarta.validation.constraints.DecimalMin;
import org.openapitools.jackson.nullable.JsonNullable;

import java.math.BigDecimal;
import java.time.Instant;

/**
 * Giai đoạn 9 việc 3b — admin sửa gói cước ({@code PATCH}, {@code application/merge-patch+json}).
 *
 * <p>"Ngừng bán" = {@code lifecycleStatus: "Retired"} thay vì xóa: đơn hàng cũ vẫn tham chiếu được
 * id gói, còn giá của đơn cũ không đổi vì order-management lưu giá TẠI THỜI ĐIỂM MUA (B-13).
 *
 * <p>B-15 (RFC 7396): không gửi = giữ nguyên; {@code null} = xóa — chỉ {@code description} và
 * {@code validForStart/End} xóa được (cột cho phép NULL); {@code name/priceAmount/lifecycleStatus} bắt buộc
 * → {@code null} = 422. Lý do dùng {@link JsonNullable}: xem PatchCustomerRequest của customer-service.
 */
public record PatchOfferingRequest(
        JsonNullable<String> name,
        JsonNullable<String> description,
        JsonNullable<@DecimalMin("0.0") BigDecimal> priceAmount,
        JsonNullable<LifecycleStatus> lifecycleStatus,
        JsonNullable<Instant> validForStart,
        JsonNullable<Instant> validForEnd
) {}
