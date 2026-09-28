package com.bss.customer.config;

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
 * Giai đoạn 9 việc 3 — ADR-008 quyết định 4: customer-service TỰ kiểm JWT (zero-trust), không tin
 * header do gateway chèn. Công tắc {@code bss.auth.enabled} giống hệt api-gateway (GĐ7): tắt ở
 * dev/staging/prod cho tới khi Keycloak lên AWS (GĐ9 việc 7), bật ở kind + docker-compose.
 *
 * <p>Luật (ADR-008 quyết định 5):
 * <ul>
 *   <li>{@code /customer/me} — role {@code customer}: khách tự tạo/đọc/sửa hồ sơ của CHÍNH mình.</li>
 *   <li>Mọi thứ khác dưới {@code /customer} — chỉ role {@code admin}.</li>
 * </ul>
 * Luật phân quyền nằm ở ĐÂY (cạnh dữ liệu), gateway chỉ chặn thô để trả 401 sớm.
 */
@Configuration
public class SecurityConfig {

    static final String BASE = "/tmf-api/customerManagement/v4/customer";

    @Bean
    @ConditionalOnProperty(name = "bss.auth.enabled", havingValue = "true")
    SecurityFilterChain enforcedFilterChain(HttpSecurity http) throws Exception {
        http.csrf(csrf -> csrf.disable()) // API stateless dùng Bearer token, không có cookie phiên → không có CSRF
                .sessionManagement(s -> s.sessionCreationPolicy(SessionCreationPolicy.STATELESS))
                .authorizeHttpRequests(auth -> auth
                        // ResponseStatusException (401/409/422) → Tomcat sendError → FORWARD nội bộ tới
                        // /error. Không mở dispatch ERROR thì `denyAll()` bên dưới chặn luôn /error và
                        // mọi 409/422 thật biến thành 403. MockMvc KHÔNG mô phỏng bước forward này nên
                        // test IT vẫn xanh dù có lỗi — chỉ lộ ra khi chạy thật (kiểm trên kind).
                        .dispatcherTypeMatchers(DispatcherType.ERROR).permitAll()
                        .requestMatchers("/actuator/**").permitAll()
                        .requestMatchers(HttpMethod.GET, BASE + "/me").hasRole("customer")
                        .requestMatchers(HttpMethod.POST, BASE + "/me").hasRole("customer")
                        .requestMatchers(HttpMethod.PATCH, BASE + "/me").hasRole("customer")
                        .requestMatchers(BASE, BASE + "/**").hasRole("admin")
                        .anyRequest().denyAll())
                .oauth2ResourceServer(o -> o.jwt(j -> j.jwtAuthenticationConverter(keycloakAuthenticationConverter())));
        return http.build();
    }

    /** Tắt auth: giữ NGUYÊN hành vi mở như trước GĐ9 (mọi endpoint cũ không đổi). */
    @Bean
    @ConditionalOnProperty(name = "bss.auth.enabled", havingValue = "false", matchIfMissing = true)
    SecurityFilterChain openFilterChain(HttpSecurity http) throws Exception {
        http.csrf(csrf -> csrf.disable())
                .sessionManagement(s -> s.sessionCreationPolicy(SessionCreationPolicy.STATELESS))
                .authorizeHttpRequests(auth -> auth.anyRequest().permitAll());
        return http.build();
    }

    /**
     * Keycloak để role trong {@code realm_access.roles} (JSON lồng nhau), không phải claim
     * {@code scope} phẳng mà converter mặc định của Spring đọc. Thiếu bộ này, {@code hasRole("admin")}
     * luôn từ chối kể cả khi token có role thật — cùng bài học đã gặp ở api-gateway (GĐ7).
     */
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
