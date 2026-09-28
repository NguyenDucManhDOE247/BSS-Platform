package com.bss.order.client;

/**
 * Tài khoản đăng nhập chưa tạo hồ sơ khách hàng ({@code GET /customer/me} → 404). Lỗi của người
 * dùng (chưa hoàn tất hồ sơ), không phải lỗi tạm thời → Resilience4j bỏ qua, không retry, không
 * tính vào circuit breaker (xem {@code ignore-exceptions} trong application.yml).
 */
public class NoCustomerProfileException extends RuntimeException {
    public NoCustomerProfileException() {
        super("Tài khoản chưa có hồ sơ khách hàng — hoàn tất hồ sơ trước khi đặt hàng");
    }
}
