package com.bss.order.service;

/**
 * Giai đoạn 9 (ADR-008 quyết định 3): khách chưa được admin duyệt ({@code Initialized}) hoặc đã bị
 * khóa ({@code Suspended}) → không được đặt hàng. 422: yêu cầu đúng cú pháp nhưng trạng thái nghiệp
 * vụ chưa cho phép; web-portal hiển thị nguyên văn {@code detail} cho khách.
 */
public class CustomerNotActiveException extends RuntimeException {
    public CustomerNotActiveException(String status) {
        super("Tài khoản chưa được duyệt để mua gói (trạng thái hiện tại: " + status
                + ") — vui lòng chờ nhân viên duyệt hồ sơ");
    }
}
