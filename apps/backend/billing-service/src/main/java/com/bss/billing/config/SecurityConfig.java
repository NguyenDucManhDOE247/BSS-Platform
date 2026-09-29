package com.bss.billing.config;

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
 * Giai đoạn 9 việc 3d — ADR-008 quyết định 4, 5: billing-service tự kiểm JWT.
 * <ul>
 *   <li>Đọc hóa đơn / billing account ({@code GET}) — {@code customer} (chỉ của mình, lọc ở service)
 *       hoặc {@code admin}.</li>
 *   <li>Mở billing account thủ công ({@code POST}) — chỉ {@code admin} (bình thường account tự mở
 *       khi có hóa đơn đầu tiên từ event).</li>
 * </ul>
 * Tạo hóa đơn KHÔNG đi qua HTTP (SQS listener, trong process) nên không chịu các luật này.
 */
@Configuration
public class SecurityConfig {

    static final String BILLING = "/tmf-api/billingManagement/v4";

    @Bean
    @ConditionalOnProperty(name = "bss.auth.enabled", havingValue = "true")
    SecurityFilterChain enforcedFilterChain(HttpSecurity http) throws Exception {
        http.csrf(csrf -> csrf.disable())
                .sessionManagement(s -> s.sessionCreationPolicy(SessionCreationPolicy.STATELESS))
                .authorizeHttpRequests(auth -> auth
                        // Xem customer-service SecurityConfig: không mở dispatch ERROR thì lỗi đi qua
                        // /error biến thành 403.
                        .dispatcherTypeMatchers(DispatcherType.ERROR).permitAll()
                        .requestMatchers("/actuator/**").permitAll()
                        // Doanh thu toàn hệ thống — chỉ admin. PHẢI khai TRƯỚC luật GET chung bên dưới
                        // (luật đầu tiên khớp sẽ thắng).
                        .requestMatchers(HttpMethod.GET, BILLING + "/customerBill/summary").hasRole("admin")
                        .requestMatchers(HttpMethod.GET, BILLING + "/**").hasAnyRole("customer", "admin")
                        .requestMatchers(HttpMethod.POST, BILLING + "/billingAccount").hasRole("admin")
                        .anyRequest().denyAll())
                .oauth2ResourceServer(o -> o.jwt(j -> j.jwtAuthenticationConverter(keycloakAuthenticationConverter())));
        return http.build();
    }

    /** Tắt auth: giữ NGUYÊN hành vi mở như trước GĐ9. */
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
