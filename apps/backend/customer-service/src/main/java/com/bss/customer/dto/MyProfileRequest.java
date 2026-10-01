package com.bss.customer.dto;

import org.openapitools.jackson.nullable.JsonNullable;

/**
 * Giai đoạn 9 (ADR-008): khách tự tạo ({@code POST /customer/me}) hoặc sửa
 * ({@code PATCH /customer/me}) hồ sơ của chính mình.
 *
 * <p>CỐ Ý chỉ có 2 trường. {@code email} lấy từ token Keycloak (không cho khách tự khai 1 email khác
 * với tài khoản đăng nhập); {@code status} chỉ admin đổi được (duyệt/khóa). Gửi thêm 2 trường đó →
 * 400, nhờ {@code fail-on-unknown-properties: true} (cùng cơ chế chặn mass-assignment của B-15).
 *
 * <p>{@link JsonNullable} (B-15, RFC 7396): PATCH không gửi trường = giữ nguyên; {@code "phoneNumber": null}
 * = xóa số điện thoại; {@code name} bắt buộc → {@code null} hoặc chuỗi trống = 422. POST bắt buộc có
 * {@code name} (kiểm ở service).
 */
public record MyProfileRequest(
        JsonNullable<String> name,
        JsonNullable<String> phoneNumber
) {}
