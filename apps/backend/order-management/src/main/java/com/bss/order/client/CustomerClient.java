package com.bss.order.client;

import io.github.resilience4j.circuitbreaker.annotation.CircuitBreaker;
import io.github.resilience4j.retry.annotation.Retry;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.boot.web.client.ClientHttpRequestFactories;
import org.springframework.boot.web.client.ClientHttpRequestFactorySettings;
import org.springframework.stereotype.Component;
import org.springframework.web.client.HttpClientErrorException;
import org.springframework.web.client.RestClient;
import org.springframework.web.client.RestClientException;

import java.time.Duration;

/**
 * Giai đoạn 9 việc 3c (ADR-008 quyết định 4) — hỏi customer-service "khách đang đăng nhập là ai,
 * đã được duyệt chưa" bằng {@code GET /customer/me}, CHUYỂN TIẾP token của chính khách đó.
 *
 * <p>Vì sao không dùng 1 "tài khoản dịch vụ" riêng cho order-management: tài khoản đó sẽ cần quyền
 * đọc MỌI khách hàng; lộ nó = lộ toàn bộ dữ liệu khách. Chuyển tiếp token của người dùng giữ đúng
 * nguyên tắc "service chỉ làm được đúng những gì người dùng đó được phép làm".
 *
 * <p>Resilience: timeout + retry + circuit breaker giống {@link ProductCatalogClient} (B-13) — xem
 * {@code resilience4j.*.instances.customerService} trong application.yml.
 */
@Component
public class CustomerClient {

    private final RestClient restClient;

    public CustomerClient(RestClient.Builder builder,
                          @Value("${bss.clients.customer-service.base-url}") String baseUrl) {
        var timeouts = ClientHttpRequestFactorySettings.DEFAULTS
                .withConnectTimeout(Duration.ofSeconds(1))
                .withReadTimeout(Duration.ofSeconds(2));
        this.restClient = builder
                .baseUrl(baseUrl)
                .requestFactory(ClientHttpRequestFactories.get(timeouts))
                .build();
    }

    /**
     * @param bearerToken token thô của khách đang gọi order-management (không kèm "Bearer ").
     * @throws NoCustomerProfileException          tài khoản chưa có hồ sơ (404) — lỗi người dùng.
     * @throws CustomerServiceUnavailableException lỗi mạng / 5xx / 401-403 bất thường — tạm thời.
     */
    @CircuitBreaker(name = "customerService")
    @Retry(name = "customerService")
    public CustomerSnapshot me(String bearerToken) {
        try {
            return restClient.get()
                    .uri("/tmf-api/customerManagement/v4/customer/me")
                    .headers(h -> h.setBearerAuth(bearerToken))
                    .retrieve()
                    .body(CustomerSnapshot.class);
        } catch (HttpClientErrorException.NotFound e) {
            throw new NoCustomerProfileException();
        } catch (RestClientException e) {
            // Gồm cả 401/403: token đã được CHÍNH order-management kiểm hợp lệ ngay trước đó, nên
            // customer-service từ chối nó là dấu hiệu cấu hình lệch giữa 2 service (issuer/JWKS),
            // không phải lỗi của khách → 503 + log, không đổ lỗi cho người dùng bằng 4xx.
            throw new CustomerServiceUnavailableException(e);
        }
    }
}
