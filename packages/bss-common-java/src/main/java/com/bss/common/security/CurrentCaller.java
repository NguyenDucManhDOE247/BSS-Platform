package com.bss.common.security;

import org.springframework.http.HttpStatus;
import org.springframework.security.core.GrantedAuthority;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.security.oauth2.server.resource.authentication.JwtAuthenticationToken;
import org.springframework.web.server.ResponseStatusException;

/**
 * Người đang gọi API là ai — đọc từ JWT mà Spring Security đã kiểm chữ ký + {@code iss} + hạn (ADR-008).
 * Mỗi service đăng ký bằng {@code @Import(CurrentCaller.class)} (package này nằm ngoài vùng quét của service).
 *
 * <p>Từ 0.2.0 thay 3 bản riêng (customer {@code CurrentUser}, order + billing {@code CurrentCaller}) — B-15.
 * Gộp lại sửa luôn 1 chỗ lệch: thiếu JWT thì bản của order/billing ném {@code IllegalStateException}
 * (→ HTTP 500), bản của customer trả 401. Bây giờ cả 3 đều 401: SecurityConfig lẽ ra đã chặn trước khi tới
 * đây — nếu lọt, "chưa đăng nhập" mới là câu trả lời đúng, không phải "lỗi máy chủ".
 */
public class CurrentCaller {

    /** Role {@code admin} của realm Keycloak (converter trong SecurityConfig thêm tiền tố {@code ROLE_}). */
    public static final String ADMIN_AUTHORITY = "ROLE_admin";

    /** Admin thấy mọi dữ liệu; khách chỉ thấy của mình (lọc ở service). */
    public boolean seesEverything() {
        return SecurityContextHolder.getContext().getAuthentication() instanceof JwtAuthenticationToken t
                && t.getAuthorities().stream().map(GrantedAuthority::getAuthority).anyMatch(ADMIN_AUTHORITY::equals);
    }

    /** {@code sub} của Keycloak — định danh bất biến của tài khoản, khóa chủ sở hữu (ADR-008 quyết định 3, 5). */
    public String subject() {
        return jwt().getSubject();
    }

    /** Email trong token; {@code null} nếu tài khoản Keycloak không có email. */
    public String email() {
        return jwt().getClaimAsString("email");
    }

    /** Claim {@code email_verified} — thiếu claim = chưa xác thực. */
    public boolean emailVerified() {
        return Boolean.TRUE.equals(jwt().getClaimAsBoolean("email_verified"));
    }

    /** Token thô để CHUYỂN TIẾP sang service khác bằng chính danh tính người dùng (không dùng tài khoản dịch vụ). */
    public String bearerToken() {
        return jwt().getTokenValue();
    }

    private Jwt jwt() {
        if (SecurityContextHolder.getContext().getAuthentication() instanceof JwtAuthenticationToken t) {
            return t.getToken();
        }
        throw new ResponseStatusException(HttpStatus.UNAUTHORIZED, "Cần đăng nhập");
    }
}
