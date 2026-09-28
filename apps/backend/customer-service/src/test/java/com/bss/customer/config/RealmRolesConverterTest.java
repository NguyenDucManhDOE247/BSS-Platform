package com.bss.customer.config;

import org.junit.jupiter.api.Test;
import org.springframework.security.core.GrantedAuthority;
import org.springframework.security.oauth2.jwt.Jwt;

import java.time.Instant;
import java.util.List;
import java.util.Map;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * Token Keycloak THẬT không có claim "scope" chứa role — role nằm ở {@code realm_access.roles}.
 * Bộ chuyển đổi mặc định của Spring đọc "scope" nên sẽ trả rỗng → mọi {@code hasRole} từ chối
 * (lỗi đã gặp thật ở api-gateway, GĐ7). Test này khóa hành vi đúng cho customer-service.
 */
class RealmRolesConverterTest {

    private static Jwt jwt(Map<String, Object> claims) {
        var b = Jwt.withTokenValue("t").header("alg", "RS256").subject("sub-1")
                .issuedAt(Instant.now()).expiresAt(Instant.now().plusSeconds(60));
        claims.forEach(b::claim);
        return b.build();
    }

    private static List<String> names(java.util.Collection<GrantedAuthority> a) {
        return a.stream().map(GrantedAuthority::getAuthority).toList();
    }

    @Test
    void realm_roles_become_ROLE_prefixed_authorities() {
        var token = jwt(Map.of("realm_access", Map.of("roles", List.of("customer", "default-roles-bss"))));
        assertThat(names(SecurityConfig.realmRoles().convert(token)))
                .containsExactlyInAnyOrder("ROLE_customer", "ROLE_default-roles-bss");
    }

    @Test
    void scope_claim_is_ignored_and_missing_realm_access_gives_no_roles() {
        var token = jwt(Map.of("scope", "openid email profile"));
        assertThat(SecurityConfig.realmRoles().convert(token)).isEmpty();
    }
}
