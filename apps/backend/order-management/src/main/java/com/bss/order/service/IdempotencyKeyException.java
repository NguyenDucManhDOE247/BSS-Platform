package com.bss.order.service;

import org.springframework.http.HttpStatus;

/**
 * B-15 — header {@code Idempotency-Key} dùng sai. Mỗi tình huống một mã HTTP để client biết phải làm gì
 * (theo bản nháp IETF draft-ietf-httpapi-idempotency-key-header):
 * <ul>
 *   <li>{@link #malformed} → 400: sửa header.</li>
 *   <li>{@link #reusedWithDifferentRequest} → 422: key này đã gắn với một đơn KHÁC nội dung — sinh key mới
 *       cho đơn mới, đừng dùng lại.</li>
 *   <li>{@link #concurrentDuplicate} → 409: một request cùng key vừa tạo đơn xong trong lúc request này
 *       đang chạy — gửi lại sẽ nhận đúng đơn đó.</li>
 * </ul>
 */
public class IdempotencyKeyException extends RuntimeException {

    private final HttpStatus status;

    private IdempotencyKeyException(HttpStatus status, String message) {
        super(message);
        this.status = status;
    }

    public HttpStatus status() {
        return status;
    }

    public static IdempotencyKeyException malformed() {
        return new IdempotencyKeyException(HttpStatus.BAD_REQUEST,
                "Idempotency-Key phải dài 1–255 ký tự ASCII in được");
    }

    public static IdempotencyKeyException reusedWithDifferentRequest() {
        return new IdempotencyKeyException(HttpStatus.UNPROCESSABLE_ENTITY,
                "Idempotency-Key này đã dùng cho một đơn có nội dung khác — dùng key mới cho đơn mới");
    }

    public static IdempotencyKeyException concurrentDuplicate() {
        return new IdempotencyKeyException(HttpStatus.CONFLICT,
                "Một request cùng Idempotency-Key vừa được xử lý — gửi lại để nhận đơn đã tạo");
    }
}
