package com.bss.product.security;

import org.springframework.security.core.GrantedAuthority;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.stereotype.Component;

/**
 * Giai đoạn 9 (ADR-008 quyết định 5): người gọi có được thấy MỌI gói cước (kể cả đã ngừng bán)
 * không? Có = admin. Không = khách đã đăng nhập hoặc chưa đăng nhập → chỉ thấy gói đang bán.
 */
@Component
public class CallerAccess {

    public boolean seesEntireCatalog() {
        var auth = SecurityContextHolder.getContext().getAuthentication();
        return auth != null && auth.getAuthorities().stream()
                .map(GrantedAuthority::getAuthority)
                .anyMatch("ROLE_admin"::equals);
    }
}
