package com.bss.gateway.config;

import static org.assertj.core.api.Assertions.assertThat;

import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.reactive.AutoConfigureWebTestClient;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.http.HttpStatus;
import org.springframework.security.test.web.reactive.server.SecurityMockServerConfigurers;
import org.springframework.test.context.ActiveProfiles;
import org.springframework.test.web.reactive.server.WebTestClient;

/**
 * Giai đoạn 7, việc 6 (B-18): kiểm chứng đúng LỚP QUYẾT ĐỊNH (401/403/pass) — không cần
 * customer-service thật chạy phía sau (gateway chỉ là reverse proxy, "pass" nghĩa là security
 * không chặn, downstream có phản hồi thế nào là chuyện của test khác/kiểm chứng thủ công trên
 * kind — xem docs/runbooks/auth.md).
 *
 * <p>{@code mockJwt()} tiêm thẳng một Authentication đã "giải mã" sẵn vào ngữ cảnh request — KHÔNG
 * cần Keycloak/JwtDecoder thật chạy trong test này (đó là lý do test chạy được trong `mvn test`
 * bình thường, không cần Testcontainers/mạng ngoài).
 */
@SpringBootTest(
        webEnvironment = SpringBootTest.WebEnvironment.RANDOM_PORT,
        properties = {
            "bss.auth.enabled=true",
            // Bắt buộc phải có (dù không dùng thật trong test) để Spring Boot tạo bean
            // ReactiveJwtDecoder — thiếu dòng này, context không khởi động được vì
            // enforcedFilterChain gọi .oauth2ResourceServer(...).
            "spring.security.oauth2.resourceserver.jwt.issuer-uri=http://localhost/realms/bss"
        })
@AutoConfigureWebTestClient
@ActiveProfiles("sectest") // route URI trỏ cổng loopback không ai nghe — xem application-sectest.yml
class SecurityConfigTest {

    @Autowired
    private WebTestClient webTestClient;

    @Test
    void actuatorHealth_khongCanToken() {
        webTestClient.get().uri("/actuator/health")
                .exchange()
                .expectStatus().is2xxSuccessful();
    }

    @Test
    void GET_congKhai_khongCanToken() {
        webTestClient.get().uri("/api/tmf-api/productCatalog/v4/productOffering")
                .exchange()
                .expectStatus().value(status -> assertThat(status).isNotEqualTo(HttpStatus.UNAUTHORIZED.value()));
    }

    @Test
    void POST_khongCoToken_bi401() {
        webTestClient.post().uri("/api/tmf-api/orderManagement/v4/productOrder")
                .exchange()
                .expectStatus().isUnauthorized();
    }

    @Test
    void POST_customerManagement_roleCustomer_bi403() {
        webTestClient.mutateWith(SecurityMockServerConfigurers.mockJwt().authorities(() -> "ROLE_customer"))
                .post().uri("/api/tmf-api/customerManagement/v4/customer")
                .exchange()
                .expectStatus().isForbidden();
    }

    @Test
    void POST_customerManagement_roleAdmin_khongBiChan() {
        webTestClient.mutateWith(SecurityMockServerConfigurers.mockJwt().authorities(() -> "ROLE_admin"))
                .post().uri("/api/tmf-api/customerManagement/v4/customer")
                .exchange()
                .expectStatus().value(status -> assertThat(status)
                        .as("security phải cho qua — 401/403 nghĩa là bị security chặn oan")
                        .isNotIn(HttpStatus.UNAUTHORIZED.value(), HttpStatus.FORBIDDEN.value()));
    }

    @Test
    void POST_order_coTokenBatKyRole_khongBiChan() {
        // orderManagement chỉ cần "đã đăng nhập" (authenticated()), không cần role cụ thể.
        webTestClient.mutateWith(SecurityMockServerConfigurers.mockJwt().authorities(() -> "ROLE_customer"))
                .post().uri("/api/tmf-api/orderManagement/v4/productOrder")
                .exchange()
                .expectStatus().value(status -> assertThat(status)
                        .isNotIn(HttpStatus.UNAUTHORIZED.value(), HttpStatus.FORBIDDEN.value()));
    }
}
