package com.bss.customer.security;

import org.springframework.http.HttpStatus;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.security.oauth2.server.resource.authentication.JwtAuthenticationToken;
import org.springframework.stereotype.Component;
import org.springframework.web.server.ResponseStatusException;

/**
 * Danh tính người gọi, lấy từ JWT đã được Spring Security kiểm chữ ký + {@code iss} + hạn.
 *
 * <p>Khi TẮT auth ({@code bss.auth.enabled=false}) không có JWT nào → mọi endpoint "của tôi" trả
 * 401 thay vì đoán bừa người gọi là ai.
 */
@Component
public class CurrentUser {

    /** {@code sub} của Keycloak — định danh bất biến của tài khoản (ADR-008 quyết định 3). */
    public String subject() {
        return token().getToken().getSubject();
    }

    /** Email trong token; null nếu tài khoản Keycloak không có email. */
    public String email() {
        return token().getToken().getClaimAsString("email");
    }

    /**
     * Claim {@code email_verified} của Keycloak (true khi người dùng đã bấm link xác thực email).
     * Thiếu claim = chưa xác thực.
     */
    public boolean emailVerified() {
        return Boolean.TRUE.equals(token().getToken().getClaimAsBoolean("email_verified"));
    }

    private JwtAuthenticationToken token() {
        var auth = SecurityContextHolder.getContext().getAuthentication();
        if (auth instanceof JwtAuthenticationToken jwt) {
            return jwt;
        }
        throw new ResponseStatusException(HttpStatus.UNAUTHORIZED, "Cần đăng nhập");
    }
}
