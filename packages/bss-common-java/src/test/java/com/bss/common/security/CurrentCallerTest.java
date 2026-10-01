package com.bss.common.security;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.time.Instant;
import java.util.List;
import java.util.Map;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.Test;
import org.springframework.http.HttpStatus;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.authority.SimpleGrantedAuthority;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.security.oauth2.server.resource.authentication.JwtAuthenticationToken;
import org.springframework.web.server.ResponseStatusException;

class CurrentCallerTest {

    private final CurrentCaller caller = new CurrentCaller();

    @AfterEach
    void clear() {
        SecurityContextHolder.clearContext();
    }

    private static void signIn(Map<String, Object> claims, String... authorities) {
        Jwt jwt = Jwt.withTokenValue("raw.jwt.value")
                .header("alg", "RS256")
                .subject("sub-123")
                .claims(c -> c.putAll(claims))
                .issuedAt(Instant.now())
                .expiresAt(Instant.now().plusSeconds(300))
                .build();
        var granted = List.of(authorities).stream().map(SimpleGrantedAuthority::new).toList();
        SecurityContextHolder.getContext().setAuthentication(new JwtAuthenticationToken(jwt, granted));
    }

    @Test
    void customerReadsOwnIdentityFromTheToken() {
        signIn(Map.of("email", "a@example.com", "email_verified", true), "ROLE_customer");
        assertEquals("sub-123", caller.subject());
        assertEquals("a@example.com", caller.email());
        assertTrue(caller.emailVerified());
        assertEquals("raw.jwt.value", caller.bearerToken());
        assertFalse(caller.seesEverything());
    }

    @Test
    void adminSeesEverything() {
        signIn(Map.of(), CurrentCaller.ADMIN_AUTHORITY);
        assertTrue(caller.seesEverything());
    }

    @Test
    void missingEmailClaimsMeanNullAndUnverified() {
        signIn(Map.of());
        assertNull(caller.email());
        assertFalse(caller.emailVerified());
    }

    @Test
    void noJwtIs401NotServerError() {
        // Bản cũ của order/billing ném IllegalStateException → HTTP 500.
        var ex = assertThrows(ResponseStatusException.class, caller::subject);
        assertEquals(HttpStatus.UNAUTHORIZED, ex.getStatusCode());
        assertFalse(caller.seesEverything());

        SecurityContextHolder.getContext().setAuthentication(
                new UsernamePasswordAuthenticationToken("basic-user", "pw", List.of()));
        assertThrows(ResponseStatusException.class, caller::bearerToken);
    }
}
