package com.bss.customer.paging;

import org.springframework.data.domain.Pageable;
import org.springframework.data.domain.Sort;

/**
 * B-15 fix ("mất bản ghi khi phân trang"): {@code PageRequest.of(offset / limit, limit, sort)}
 * only computes the right page when {@code offset} is an exact multiple of {@code limit} —
 * {@code PageRequest} always recomputes {@code getOffset()} as {@code pageNumber * pageSize}
 * internally, so e.g. {@code ?offset=10&limit=20} truncates (integer division) to page 0 and
 * silently returns records 0–19 instead of 10–29.
 *
 * <p>Implementing {@link Pageable} directly lets {@link #getOffset()} return exactly what the
 * caller asked for; Spring Data JPA's query execution reads {@code getOffset()}/
 * {@code getPageSize()} straight off the {@code Pageable}, so that's enough to fix it.
 *
 * <p>Duplicated across the 4 backend services for now — see the identical class in
 * order-management for why (no shared Maven reactor wiring to bss-common-java yet).
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
        return hasPrevious() ? new OffsetPageRequest(offset - limit, limit, sort) : first();
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
