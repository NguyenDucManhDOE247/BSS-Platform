package com.bss.order.model;

import jakarta.persistence.*;
import org.springframework.data.domain.Persistable;

import java.io.Serializable;
import java.time.Instant;
import java.util.Objects;
import java.util.UUID;

/**
 * B-15: một header {@code Idempotency-Key} đã dùng để tạo đơn — xem V4__idempotency_key.sql cho lý do
 * từng cột. Khóa ghép (chủ sở hữu, key): key chỉ có nghĩa trong phạm vi một người dùng.
 *
 * <p>{@link Persistable}: id do mình gán (không sinh tự động) nên Spring Data đoán "đã tồn tại" và gọi
 * {@code merge()} — tức SELECT rồi UPDATE nếu thấy. Với 2 request cùng key chạy song song, request thua sẽ
 * UPDATE đè key sang đơn của nó thay vì vấp PRIMARY KEY → 2 đơn, đúng thứ bảng này phải chặn. Cùng lỗi đã
 * gặp thật ở billing ({@code ProcessedEvent}, docs/POSTMORTEMS.md PM-01) — ở đây {@code save()} luôn INSERT.
 */
@Entity
@Table(name = "idempotency_key")
public class IdempotencyKey implements Persistable<IdempotencyKey.Key> {

    @EmbeddedId
    private Key id;

    @Transient
    private boolean isNew = true;

    /** SHA-256 (hex) của nội dung request — cùng key, khác nội dung → 422. */
    @Column(name = "request_hash", nullable = false, length = 64)
    private String requestHash;

    @Column(name = "order_id", nullable = false)
    private UUID orderId;

    @Column(name = "created_at", nullable = false)
    private Instant createdAt;

    protected IdempotencyKey() {
    }

    public static IdempotencyKey of(String ownerSub, String key, String requestHash, UUID orderId) {
        var k = new IdempotencyKey();
        k.id = new Key(ownerSub, key);
        k.requestHash = requestHash;
        k.orderId = orderId;
        k.createdAt = Instant.now();
        return k;
    }

    @Override
    public Key getId() { return id; }

    @Override
    public boolean isNew() { return isNew; }

    @PostLoad
    @PostPersist
    void markPersisted() { isNew = false; }

    public String getRequestHash() { return requestHash; }
    public UUID getOrderId() { return orderId; }

    @Embeddable
    public static class Key implements Serializable {

        @Column(name = "owner_sub", nullable = false, length = 64)
        private String ownerSub;

        @Column(name = "idem_key", nullable = false, length = 255)
        private String idemKey;

        protected Key() {
        }

        public Key(String ownerSub, String idemKey) {
            this.ownerSub = ownerSub;
            this.idemKey = idemKey;
        }

        @Override
        public boolean equals(Object o) {
            return o instanceof Key k && ownerSub.equals(k.ownerSub) && idemKey.equals(k.idemKey);
        }

        @Override
        public int hashCode() {
            return Objects.hash(ownerSub, idemKey);
        }
    }
}
