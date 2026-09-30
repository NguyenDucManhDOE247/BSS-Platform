package com.bss.order.security;

import org.springframework.security.core.GrantedAuthority;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.security.oauth2.server.resource.authentication.JwtAuthenticationToken;
import org.springframework.stereotype.Component;

import java.util.Optional;

/**
 * Giai đoạn 9 (ADR-008): người đang gọi order-management là ai.
 *
 * <p>Mọi request tới đây đã qua {@code SecurityConfig} (JWT hợp lệ). Nhánh "auth tắt" (công tắc
 * {@code bss.auth.enabled}) đã xóa 2026-09-30 khi mọi môi trường đều có Keycloak.
 */
@Component
public class CurrentCaller {

    /** Admin thấy mọi dữ liệu; khách chỉ thấy của mình (lọc ở service). */
    public boolean seesEverything() {
        return jwt().map(t -> t.getAuthorities().stream()
                .map(GrantedAuthority::getAuthority)
                .anyMatch("ROLE_admin"::equals)).orElse(false);
    }

    /** {@code sub} của Keycloak — định danh chủ sở hữu đóng dấu lên đơn (ADR-008 quyết định 5). */
    public String subject() {
        return jwt().map(t -> t.getToken().getSubject())
                .orElseThrow(() -> new IllegalStateException("Không có JWT — SecurityConfig lẽ ra đã trả 401 trước khi tới đây"));
    }

    /** Token thô để CHUYỂN TIẾP sang customer-service (không dùng tài khoản dịch vụ). */
    public String bearerToken() {
        return jwt().map(t -> t.getToken().getTokenValue())
                .orElseThrow(() -> new IllegalStateException("Không có JWT — SecurityConfig lẽ ra đã trả 401 trước khi tới đây"));
    }

    private Optional<JwtAuthenticationToken> jwt() {
        return SecurityContextHolder.getContext().getAuthentication() instanceof JwtAuthenticationToken t
                ? Optional.of(t) : Optional.empty();
    }
}
