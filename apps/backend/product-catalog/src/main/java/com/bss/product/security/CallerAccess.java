package com.bss.product.security;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.security.core.GrantedAuthority;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.stereotype.Component;

/**
 * Giai đoạn 9 (ADR-008 quyết định 5): người gọi có được thấy MỌI gói cước (kể cả đã ngừng bán)
 * không? Có = admin, HOẶC auth đang tắt (dev/staging/prod cho tới GĐ9 việc 7 — giữ nguyên hành vi
 * cũ: không lọc gì). Không = khách đã đăng nhập hoặc chưa đăng nhập → chỉ thấy gói đang bán.
 */
@Component
public class CallerAccess {

    private final boolean authEnabled;

    public CallerAccess(@Value("${bss.auth.enabled:false}") boolean authEnabled) {
        this.authEnabled = authEnabled;
    }

    public boolean seesEntireCatalog() {
        if (!authEnabled) {
            return true;
        }
        var auth = SecurityContextHolder.getContext().getAuthentication();
        return auth != null && auth.getAuthorities().stream()
                .map(GrantedAuthority::getAuthority)
                .anyMatch("ROLE_admin"::equals);
    }
}
