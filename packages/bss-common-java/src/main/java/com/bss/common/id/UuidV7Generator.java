package com.bss.common.id;

import java.util.UUID;
import org.hibernate.engine.spi.SharedSessionContractImplementor;
import org.hibernate.id.uuid.UuidValueGenerator;

/**
 * Cắm {@link UuidV7} vào Hibernate. Hibernate 6.6 (Spring Boot 3.5) chỉ có sẵn kiểu RANDOM (v4) và TIME
 * (v1) — chưa có v7 — nhưng cho phép thay thuật toán:
 *
 * <pre>
 * &#64;Id
 * &#64;GeneratedValue
 * &#64;UuidGenerator(algorithm = UuidV7Generator.class)
 * private UUID id;
 * </pre>
 *
 * Khi nâng lên Hibernate 7 (có sẵn {@code UuidGenerator.Style.VERSION_7}) có thể bỏ class này.
 */
public class UuidV7Generator implements UuidValueGenerator {

    @Override
    public UUID generateUuid(SharedSessionContractImplementor session) {
        return UuidV7.generate();
    }
}
