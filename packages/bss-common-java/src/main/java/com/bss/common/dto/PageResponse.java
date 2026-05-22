package com.bss.common.dto;

import java.util.List;

/** Generic paginated response used by every list endpoint. */
public record PageResponse<T>(
        List<T> items,
        long totalCount,
        int offset,
        int limit
) {}
