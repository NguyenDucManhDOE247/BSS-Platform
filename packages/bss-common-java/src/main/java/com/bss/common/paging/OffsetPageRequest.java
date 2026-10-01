package com.bss.common.paging;

import org.springframework.data.domain.Pageable;
import org.springframework.data.domain.Sort;

/**
 * Phân trang kiểu TMF ({@code ?offset=&limit=}) cho Spring Data — B-15 "mất bản ghi khi phân trang".
 *
 * <p>Code cũ dùng {@code PageRequest.of(offset / limit, limit, sort)}: chỉ đúng khi {@code offset} chia hết
 * cho {@code limit}. {@code PageRequest} luôn tự tính {@code getOffset() = pageNumber * pageSize}, nên
 * {@code ?offset=10&limit=20} thành trang {@code 10/20 = 0} (chia nguyên) → JPA chạy {@code OFFSET 0 LIMIT 20},
 * trả bản ghi 0–19 thay vì 10–29. Class này cài {@link Pageable} trực tiếp để {@link #getOffset()} trả đúng
 * offset người gọi xin — Spring Data JPA đọc thẳng {@code getOffset()/getPageSize()} khi chạy truy vấn.
 *
 * <p>Từ 0.2.0 sống ở đây thay vì 4 bản sao giống hệt nhau trong 4 service (B-15).
 */
public final class OffsetPageRequest implements Pageable {

    private final long offset;
    private final int limit;
    private final Sort sort;

    private OffsetPageRequest(long offset, int limit, Sort sort) {
        if (offset < 0) {
            throw new IllegalArgumentException("offset must not be negative");
        }
        if (limit < 1) {
            throw new IllegalArgumentException("limit must be at least 1");
        }
        this.offset = offset;
        this.limit = limit;
        this.sort = sort;
    }

    public static OffsetPageRequest of(long offset, int limit, Sort sort) {
        return new OffsetPageRequest(offset, limit, sort);
    }

    @Override
    public int getPageNumber() {
        // Chỉ để tương thích interface (vd. log). Phân trang thật dựa vào getOffset().
        return (int) (offset / limit);
    }

    @Override
    public int getPageSize() {
        return limit;
    }

    @Override
    public long getOffset() {
        return offset;
    }

    @Override
    public Sort getSort() {
        return sort;
    }

    @Override
    public Pageable next() {
        return new OffsetPageRequest(offset + limit, limit, sort);
    }

    @Override
    public Pageable previousOrFirst() {
        return hasPrevious() ? new OffsetPageRequest(Math.max(0, offset - limit), limit, sort) : first();
    }

    @Override
    public Pageable first() {
        return new OffsetPageRequest(0, limit, sort);
    }

    @Override
    public Pageable withPage(int pageNumber) {
        return new OffsetPageRequest((long) pageNumber * limit, limit, sort);
    }

    @Override
    public boolean hasPrevious() {
        return offset > 0;
    }

    @Override
    public boolean isPaged() {
        return true;
    }
}
