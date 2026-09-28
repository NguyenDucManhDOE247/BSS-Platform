package com.bss.order.client;

/**
 * customer-service chậm/lỗi/không kết nối được. Lỗi TẠM THỜI → Resilience4j retry + tính vào
 * circuit breaker; ra ngoài là 503 ("thử lại sau"), không phải 500.
 */
public class CustomerServiceUnavailableException extends RuntimeException {
    public CustomerServiceUnavailableException(Throwable cause) {
        super("customer-service tạm thời không khả dụng — vui lòng thử lại sau", cause);
    }
}
