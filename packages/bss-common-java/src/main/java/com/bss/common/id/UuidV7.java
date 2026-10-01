package com.bss.common.id;

import java.security.SecureRandom;
import java.util.UUID;

/**
 * UUID phiên bản 7 (RFC 9562 §5.7) — quy ước PK của CLAUDE.md §7, B-15.
 *
 * <pre>
 *  0                   1                   2                   3
 *  0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
 * |                      unix_ts_ms (48 bit)                      |
 * |       unix_ts_ms              |  ver=7 |      rand_a (12)     |
 * |var=10|                  rand_b (62 bit)                       |
 * |                          rand_b                               |
 * </pre>
 *
 * Vì sao v7 thay v4 (ngẫu nhiên hoàn toàn): 48 bit đầu là thời điểm tạo → khóa mới luôn "lớn hơn" khóa cũ
 * (theo ms) → bản ghi mới chèn vào CUỐI index B-tree của Postgres thay vì một trang ngẫu nhiên → ít tách
 * trang, index gọn hơn, cache tốt hơn khi bảng lớn. Vẫn 74 bit ngẫu nhiên → không đoán được, không trùng.
 *
 * Đánh đổi: id để lộ thời điểm tạo bản ghi (ms) — chấp nhận được ở đây (đơn/hóa đơn vốn có createdAt
 * trả ra API). Không làm "đơn điệu tuyệt đối" trong cùng 1 ms (RFC §6.2 phương án 1/3): 2 id cùng ms có thể
 * lệch thứ tự — vô hại cho index, và không có code nào sắp xếp theo id thay cho createdAt.
 *
 * Kiểu cột không đổi: Postgres {@code UUID} nhận mọi phiên bản → đổi bộ sinh KHÔNG cần migration, bản ghi
 * cũ (v4) và mới (v7) sống chung một bảng.
 */
public final class UuidV7 {

    private static final SecureRandom RANDOM = new SecureRandom();

    private UuidV7() {
    }

    /** UUID v7 cho thời điểm hiện tại. */
    public static UUID generate() {
        return generate(System.currentTimeMillis());
    }

    /** UUID v7 cho {@code epochMillis} — tách riêng để test kiểm được timestamp. */
    public static UUID generate(long epochMillis) {
        if (epochMillis < 0 || epochMillis > 0xFFFF_FFFF_FFFFL) {
            throw new IllegalArgumentException("epochMillis ngoài 48 bit: " + epochMillis);
        }
        long randA = RANDOM.nextInt(1 << 12);                 // 12 bit
        long randB = RANDOM.nextLong() & 0x3FFF_FFFF_FFFF_FFFFL; // 62 bit
        long msb = (epochMillis << 16) | (0x7L << 12) | randA;
        long lsb = (0x2L << 62) | randB;                       // variant 10 (RFC 9562)
        return new UUID(msb, lsb);
    }

    /** Thời điểm (epoch ms) mã hóa trong một UUID v7. */
    public static long epochMillis(UUID uuid) {
        if (uuid.version() != 7) {
            throw new IllegalArgumentException("không phải UUID v7: " + uuid);
        }
        return uuid.getMostSignificantBits() >>> 16;
    }
}
