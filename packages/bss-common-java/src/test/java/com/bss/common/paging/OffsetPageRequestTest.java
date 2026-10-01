package com.bss.common.paging;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import org.junit.jupiter.api.Test;
import org.springframework.data.domain.Sort;

class OffsetPageRequestTest {

    private static final Sort BY_CREATED = Sort.by("createdAt");

    @Test
    void offsetNotMultipleOfLimitIsKeptExactly() {
        // Đúng ca của B-15: PageRequest.of(10 / 20, 20) đọc từ bản ghi 0 thay vì 10.
        var page = OffsetPageRequest.of(10, 20, BY_CREATED);
        assertEquals(10, page.getOffset());
        assertEquals(20, page.getPageSize());
        assertEquals(BY_CREATED, page.getSort());
    }

    @Test
    void navigatesByOffsetNotByPageNumber() {
        var page = OffsetPageRequest.of(15, 10, BY_CREATED);
        assertEquals(25, page.next().getOffset());
        assertEquals(5, page.previousOrFirst().getOffset());
        assertEquals(0, OffsetPageRequest.of(5, 10, BY_CREATED).previousOrFirst().getOffset());
        assertEquals(0, page.first().getOffset());
        assertEquals(30, page.withPage(3).getOffset());
        assertTrue(page.hasPrevious());
        assertFalse(page.first().hasPrevious());
    }

    @Test
    void rejectsInvalidArgumentsInsteadOfFailingInsideJpa() {
        assertThrows(IllegalArgumentException.class, () -> OffsetPageRequest.of(-1, 20, BY_CREATED));
        assertThrows(IllegalArgumentException.class, () -> OffsetPageRequest.of(0, 0, BY_CREATED));
    }
}
