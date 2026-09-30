package com.bss.gateway.config;

import java.util.Collection;
import java.util.List;
import java.util.Map;
import java.util.stream.Collectors;

import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.core.convert.converter.Converter;
import org.springframework.http.HttpMethod;
import org.springframework.security.authentication.AbstractAuthenticationToken;
import org.springframework.security.config.web.server.ServerHttpSecurity;
import org.springframework.security.core.GrantedAuthority;
import org.springframework.security.core.authority.SimpleGrantedAuthority;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.security.oauth2.server.resource.authentication.JwtAuthenticationConverter;
import org.springframework.security.oauth2.server.resource.authentication.ReactiveJwtAuthenticationConverterAdapter;
import org.springframework.security.web.server.SecurityWebFilterChain;

import reactor.core.publisher.Mono;

/**
 * Giai đoạn 7, việc 6 (B-18): "Gateway không kiểm token; admin-console ai vào cũng xóa được
 * khách hàng."
 *
 * <p>Auth LUÔN bật ở mọi môi trường (ADR-008 quyết định 6). Từ GĐ7 tới 2026-09-30 từng có công tắc
 * {@code bss.auth.enabled} với 1 chuỗi "mở hết" cho môi trường chưa có Keycloak; công tắc bị xóa khi
 * cả kind, docker-compose lẫn AWS đều có Keycloak — giữ nó chỉ còn là 1 cách để vô tình tắt bảo mật.
 * Thiếu cấu hình issuer/JWKS thì app KHÔNG khởi động được (fail sớm), thay vì chạy mà không kiểm token.
 */
@Configuration
public class SecurityConfig {

    /** JWT thật (Keycloak), phân quyền thô theo role — luật sở hữu chi tiết nằm ở từng service. */
    @Bean
    SecurityWebFilterChain enforcedFilterChain(ServerHttpSecurity http) {
        http.csrf(ServerHttpSecurity.CsrfSpec::disable)
                .authorizeExchange(exchanges -> exchanges
                        // Actuator (health/readiness probe, Prometheus scrape) không bao giờ đòi token —
                        // kubelet/Prometheus không có cách nào xin token, và lộ /actuator/health không
                        // phải rủi ro bảo mật thật.
                        .pathMatchers("/actuator/**").permitAll()
                        // Giai đoạn 9 (ADR-008): CHỈ duyệt gói cước là công khai (khách chưa đăng nhập vẫn
                        // xem được gói). GĐ7 từng để MỌI GET công khai → ai cũng đọc được đơn/hóa đơn/hồ sơ
                        // của người khác qua gateway.
                        .pathMatchers(HttpMethod.GET, "/api/tmf-api/productCatalog/**").permitAll()
                        // Khách tự quản lý hồ sơ của chính mình — phải khai TRƯỚC luật admin bên dưới.
                        .pathMatchers("/api/tmf-api/customerManagement/v4/customer/me").authenticated()
                        // B-18: quản lý khách hàng CHỈ admin (lỗ hổng gốc: "admin-console ai vào cũng xóa
                        // được khách hàng").
                        .pathMatchers("/api/tmf-api/customerManagement/**").hasRole("admin")
                        // Còn lại: cần đăng nhập. Gateway chỉ chặn THÔ để trả 401 sớm — luật sở hữu chi
                        // tiết ("chỉ xem đơn/hóa đơn của mình") nằm ở từng service (ADR-008 quyết định 4).
                        .anyExchange().authenticated())
                .oauth2ResourceServer(oauth2 -> oauth2.jwt(jwt -> jwt.jwtAuthenticationConverter(keycloakAuthoritiesConverter())));
        return http.build();
    }

    /**
     * Keycloak để role trong claim {@code realm_access.roles} (JSON lồng nhau), KHÔNG phải claim
     * {@code scope}/{@code scp} phẳng mà {@link JwtAuthenticationConverter} mặc định của Spring
     * Security đọc — thiếu bộ chuyển đổi này, mọi user (kể cả có role "admin" thật trong token)
     * đều bị coi là KHÔNG có authority nào, `hasRole("admin")` luôn từ chối. Đây là lỗi tích hợp
     * Keycloak phổ biến nhất — đã tự kiểm chứng bằng token thật trước khi viết class này (xem
     * nhật ký học tập): token của Keycloak KHÔNG có claim "scope" nào cả.
     */
    private Converter<Jwt, Mono<AbstractAuthenticationToken>> keycloakAuthoritiesConverter() {
        JwtAuthenticationConverter delegate = new JwtAuthenticationConverter();
        delegate.setJwtGrantedAuthoritiesConverter(this::realmRolesToAuthorities);
        return new ReactiveJwtAuthenticationConverterAdapter(delegate);
    }

    @SuppressWarnings("unchecked")
    private Collection<GrantedAuthority> realmRolesToAuthorities(Jwt jwt) {
        Map<String, Object> realmAccess = jwt.getClaimAsMap("realm_access");
        if (realmAccess == null || !(realmAccess.get("roles") instanceof List<?> roles)) {
            return List.of();
        }
        // "ROLE_" + tên role Keycloak — đúng tiền tố Spring Security cần để hasRole("admin") khớp
        // authority "ROLE_admin" (hasRole tự thêm "ROLE_" khi so sánh, hasAuthority thì không).
        return roles.stream()
                .map(Object::toString)
                .map(role -> (GrantedAuthority) new SimpleGrantedAuthority("ROLE_" + role))
                .collect(Collectors.toList());
    }
}
