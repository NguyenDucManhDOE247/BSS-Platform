package com.bss.order.paging;

import org.springframework.data.domain.Pageable;
import org.springframework.data.domain.Sort;

/**
 * B-15 fix ("mất bản ghi khi phân trang" / lost rows when paginating): the code this class
 * replaces did
 *
 * <pre>{@code PageRequest.of(offset / limit, limit, sort)}</pre>
 *
 * which only works when {@code offset} happens to be an exact multiple of {@code limit}.
 * {@code PageRequest} always recomputes its own {@code getOffset()} as
 * {@code pageNumber * pageSize} — it has no concept of an arbitrary offset. So
 * {@code ?offset=10&limit=20} truncates to page {@code 10/20 = 0} (integer division) and
 * Spring Data JPA queries {@code OFFSET 0 LIMIT 20}, silently returning records 0–19 instead
 * of 10–29. A caller paging through results one record at a time (offset=0,1,2,3,...) would
 * see the *same* page over and over.
 *
 * <p>This class implements {@link Pageable} directly so {@link #getOffset()} returns exactly
 * the offset the caller asked for — Spring Data JPA's query execution reads
 * {@code getOffset()}/{@code getPageSize()} straight off the {@code Pageable} (it does not
 * recompute offset from page number), so this is enough to fix the bug.
 *
 * <p>Duplicated (near-identically) in the other 3 backend services for now — there is no
 * shared build wiring to {@code packages/bss-common-java} yet (each service builds
 * standalone against {@code spring-boot-starter-parent}, not a local Maven reactor). Moving
 * this into the shared module once that wiring exists is tracked as a follow-up, not done
 * here to keep this change focused on the bug.
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
        // Best-effort only — kept for interface compatibility (e.g. logging). Pagination
        // itself relies on getOffset(), not this.
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
