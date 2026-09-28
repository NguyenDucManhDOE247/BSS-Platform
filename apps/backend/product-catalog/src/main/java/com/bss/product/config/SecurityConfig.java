package com.bss.product.config;

import java.util.Collection;
import java.util.List;
import java.util.Map;

import jakarta.servlet.DispatcherType;

import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.core.convert.converter.Converter;
import org.springframework.http.HttpMethod;
import org.springframework.security.config.annotation.web.builders.HttpSecurity;
import org.springframework.security.config.http.SessionCreationPolicy;
import org.springframework.security.core.GrantedAuthority;
import org.springframework.security.core.authority.SimpleGrantedAuthority;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.security.oauth2.server.resource.authentication.JwtAuthenticationConverter;
import org.springframework.security.web.SecurityFilterChain;

/**
 * Giai đoạn 9 việc 3b — ADR-008 quyết định 4, 5: product-catalog tự kiểm JWT.
 * <ul>
 *   <li>GET (duyệt gói cước, danh mục) — công khai; khách chưa đăng nhập vẫn xem được gói.
 *       Việc "khách chỉ thấy gói đang bán" lọc ở service ({@code CallerAccess}), không ở đây.</li>
 *   <li>Mọi thao tác ghi (tạo, sửa giá, ngừng bán, xóa) — chỉ role {@code admin}.</li>
 * </ul>
 * Cùng công tắc {@code bss.auth.enabled} với api-gateway / customer-service; tắt = hành vi cũ.
 */
@Configuration
public class SecurityConfig {

    static final String CATALOG = "/tmf-api/productCatalog/v4/**";

    @Bean
    @ConditionalOnProperty(name = "bss.auth.enabled", havingValue = "true")
    SecurityFilterChain enforcedFilterChain(HttpSecurity http) throws Exception {
        http.csrf(csrf -> csrf.disable())
                .sessionManagement(s -> s.sessionCreationPolicy(SessionCreationPolicy.STATELESS))
                .authorizeHttpRequests(auth -> auth
                        // Xem giải thích ở customer-service SecurityConfig: không mở dispatch ERROR thì
                        // mọi lỗi đi qua /error (ResponseStatusException...) biến thành 403.
                        .dispatcherTypeMatchers(DispatcherType.ERROR).permitAll()
                        .requestMatchers("/actuator/**").permitAll()
                        .requestMatchers(HttpMethod.GET, CATALOG).permitAll()
                        .requestMatchers(CATALOG).hasRole("admin")
                        .anyRequest().denyAll())
                .oauth2ResourceServer(o -> o.jwt(j -> j.jwtAuthenticationConverter(keycloakAuthenticationConverter())));
        return http.build();
    }

    @Bean
    @ConditionalOnProperty(name = "bss.auth.enabled", havingValue = "false", matchIfMissing = true)
    SecurityFilterChain openFilterChain(HttpSecurity http) throws Exception {
        http.csrf(csrf -> csrf.disable())
                .sessionManagement(s -> s.sessionCreationPolicy(SessionCreationPolicy.STATELESS))
                .authorizeHttpRequests(auth -> auth.anyRequest().permitAll());
        return http.build();
    }

    /** Keycloak để role trong {@code realm_access.roles} — xem customer-service SecurityConfig. */
    public static JwtAuthenticationConverter keycloakAuthenticationConverter() {
        var converter = new JwtAuthenticationConverter();
        converter.setJwtGrantedAuthoritiesConverter(realmRoles());
        return converter;
    }

    @SuppressWarnings("unchecked")
    static Converter<Jwt, Collection<GrantedAuthority>> realmRoles() {
        return jwt -> {
            Map<String, Object> realmAccess = jwt.getClaimAsMap("realm_access");
            if (realmAccess == null || !(realmAccess.get("roles") instanceof List<?> roles)) {
                return List.of();
            }
            return roles.stream()
                    .map(r -> (GrantedAuthority) new SimpleGrantedAuthority("ROLE_" + r))
                    .toList();
        };
    }
}
