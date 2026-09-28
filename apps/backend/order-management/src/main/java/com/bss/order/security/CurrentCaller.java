package com.bss.order.security;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.security.core.GrantedAuthority;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.security.oauth2.server.resource.authentication.JwtAuthenticationToken;
import org.springframework.stereotype.Component;

import java.util.Optional;

/**
 * Giai đoạn 9 (ADR-008): người đang gọi order-management là ai.
 *
 * <p>{@link #authEnabled()} = false (dev/staging/prod cho tới GĐ9 việc 7): không có JWT nào, service
 * giữ nguyên hành vi cũ (customerId lấy từ body, không lọc theo chủ sở hữu). Công tắc này bị xóa khi
 * mọi môi trường đã có Keycloak — lúc đó mọi nhánh "auth tắt" trong service cũng xóa theo.
 */
@Component
public class CurrentCaller {

    private final boolean authEnabled;

    public CurrentCaller(@Value("${bss.auth.enabled:false}") boolean authEnabled) {
        this.authEnabled = authEnabled;
    }

    public boolean authEnabled() {
        return authEnabled;
    }

    /** Admin — hoặc auth tắt (không lọc gì, như trước GĐ9). */
    public boolean seesEverything() {
        return !authEnabled || jwt().map(t -> t.getAuthorities().stream()
                .map(GrantedAuthority::getAuthority)
                .anyMatch("ROLE_admin"::equals)).orElse(false);
    }

    /** {@code sub} của Keycloak — định danh chủ sở hữu đóng dấu lên đơn (ADR-008 quyết định 5). */
    public String subject() {
        return jwt().map(t -> t.getToken().getSubject())
                .orElseThrow(() -> new IllegalStateException("Không có JWT — chỉ gọi khi authEnabled()"));
    }

    /** Token thô để CHUYỂN TIẾP sang customer-service (không dùng tài khoản dịch vụ). */
    public String bearerToken() {
        return jwt().map(t -> t.getToken().getTokenValue())
                .orElseThrow(() -> new IllegalStateException("Không có JWT — chỉ gọi khi authEnabled()"));
    }

    private Optional<JwtAuthenticationToken> jwt() {
        return SecurityContextHolder.getContext().getAuthentication() instanceof JwtAuthenticationToken t
                ? Optional.of(t) : Optional.empty();
    }
}
