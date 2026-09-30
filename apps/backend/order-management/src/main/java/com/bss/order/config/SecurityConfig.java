package com.bss.order.config;

import java.util.Collection;
import java.util.List;
import java.util.Map;

import jakarta.servlet.DispatcherType;

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
 * Giai đoạn 9 việc 3c — ADR-008 quyết định 4, 5: order-management tự kiểm JWT.
 * <ul>
 *   <li>Đặt hàng ({@code POST}) — chỉ role {@code customer} (admin không mua hộ).</li>
 *   <li>Đọc đơn ({@code GET}) — {@code customer} (chỉ đơn của mình, lọc ở service) hoặc {@code admin}.</li>
 * </ul>
 */
@Configuration
public class SecurityConfig {

    static final String ORDERS = "/tmf-api/orderManagement/v4/productOrder";

    @Bean
    SecurityFilterChain enforcedFilterChain(HttpSecurity http) throws Exception {
        http.csrf(csrf -> csrf.disable())
                .sessionManagement(s -> s.sessionCreationPolicy(SessionCreationPolicy.STATELESS))
                .authorizeHttpRequests(auth -> auth
                        // Xem customer-service SecurityConfig: không mở dispatch ERROR thì lỗi đi qua
                        // /error biến thành 403.
                        .dispatcherTypeMatchers(DispatcherType.ERROR).permitAll()
                        .requestMatchers("/actuator/**").permitAll()
                        .requestMatchers(HttpMethod.POST, ORDERS).hasRole("customer")
                        .requestMatchers(HttpMethod.GET, ORDERS, ORDERS + "/*").hasAnyRole("customer", "admin")
                        .anyRequest().denyAll())
                .oauth2ResourceServer(o -> o.jwt(j -> j.jwtAuthenticationConverter(keycloakAuthenticationConverter())));
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
