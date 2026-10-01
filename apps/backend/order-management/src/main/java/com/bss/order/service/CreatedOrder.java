package com.bss.order.service;

import com.bss.order.dto.OrderDto;

/**
 * Kết quả {@code POST productOrder}. {@code replayed = true}: request trùng {@code Idempotency-Key} của một
 * đơn đã tạo → trả lại đơn đó, không tạo đơn mới (B-15).
 */
public record CreatedOrder(OrderDto order, boolean replayed) {
}
