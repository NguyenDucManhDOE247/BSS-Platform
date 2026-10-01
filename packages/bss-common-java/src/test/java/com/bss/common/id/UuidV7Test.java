package com.bss.common.id;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.util.HashSet;
import java.util.Set;
import java.util.UUID;
import org.junit.jupiter.api.Test;

class UuidV7Test {

    @Test
    void versionAndVariantFollowRfc9562() {
        UUID id = UuidV7.generate();
        assertEquals(7, id.version());
        assertEquals(2, id.variant()); // IETF variant (bit 10)
    }

    @Test
    void encodesTheTimestampInTheFirst48Bits() {
        long t = 1_790_000_000_123L; // 2026-09
        UUID id = UuidV7.generate(t);
        assertEquals(t, UuidV7.epochMillis(id));
        // 12 ký tự hex đầu = 48 bit timestamp → đọc được bằng mắt trong log / psql
        assertEquals(String.format("%012x", t), id.toString().replace("-", "").substring(0, 12));
    }

    @Test
    void laterMillisecondSortsAfter() {
        // Đây là lý do dùng v7: id mới hơn ≥ id cũ khi so theo thứ tự byte (cách Postgres so cột UUID).
        for (int i = 0; i < 1_000; i++) {
            UUID older = UuidV7.generate(1_000_000L + i);
            UUID newer = UuidV7.generate(1_000_001L + i);
            assertTrue(Long.compareUnsigned(older.getMostSignificantBits(), newer.getMostSignificantBits()) < 0);
        }
    }

    @Test
    void sameMillisecondStillUnique() {
        Set<UUID> ids = new HashSet<>();
        for (int i = 0; i < 100_000; i++) {
            ids.add(UuidV7.generate(42L));
        }
        assertEquals(100_000, ids.size());
    }

    @Test
    void rejectsTimestampsOutside48Bits() {
        assertThrows(IllegalArgumentException.class, () -> UuidV7.generate(-1));
        assertThrows(IllegalArgumentException.class, () -> UuidV7.generate(1L << 48));
        assertThrows(IllegalArgumentException.class, () -> UuidV7.epochMillis(UUID.randomUUID()));
    }
}
