package com.bss.billing.security;

import org.springframework.security.core.GrantedAuthority;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.security.oauth2.server.resource.authentication.JwtAuthenticationToken;
import org.springframework.stereotype.Component;

import java.util.Optional;

/**
 * Giai đoạn 9 (ADR-008): người đang gọi billing-service qua HTTP là ai. Giống hệt order-management
 * ({@code com.bss.order.security.CurrentCaller}) — mỗi service giữ 1 bản vì chưa dùng chung thư viện
 * (nợ B-15: bss-common-java chưa được mọi service import).
 */
@Component
public class CurrentCaller {

    /** Admin thấy mọi dữ liệu; khách chỉ thấy của mình (lọc ở service). */
    public boolean seesEverything() {
        return jwt().map(t -> t.getAuthorities().stream()
                .map(GrantedAuthority::getAuthority)
                .anyMatch("ROLE_admin"::equals)).orElse(false);
    }

    public String subject() {
        return jwt().map(t -> t.getToken().getSubject())
                .orElseThrow(() -> new IllegalStateException("Không có JWT — SecurityConfig lẽ ra đã trả 401 trước khi tới đây"));
    }

    private Optional<JwtAuthenticationToken> jwt() {
        return SecurityContextHolder.getContext().getAuthentication() instanceof JwtAuthenticationToken t
                ? Optional.of(t) : Optional.empty();
    }
}
