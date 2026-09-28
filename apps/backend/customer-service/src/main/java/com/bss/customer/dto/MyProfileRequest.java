package com.bss.customer.dto;

/**
 * Giai đoạn 9 (ADR-008): khách tự tạo ({@code POST /customer/me}) hoặc sửa
 * ({@code PATCH /customer/me}) hồ sơ của chính mình.
 *
 * <p>CỐ Ý chỉ có 2 trường. {@code email} lấy từ token Keycloak (không cho khách tự khai 1 email khác
 * với tài khoản đăng nhập); {@code status} chỉ admin đổi được (duyệt/khóa). Gửi thêm 2 trường đó →
 * 400, nhờ {@code fail-on-unknown-properties: true} (cùng cơ chế chặn mass-assignment của B-15).
 *
 * <p>POST bắt buộc có {@code name} (kiểm ở service, vì PATCH cho phép bỏ trống = giữ nguyên).
 */
public record MyProfileRequest(
        String name,
        String phoneNumber
) {}
