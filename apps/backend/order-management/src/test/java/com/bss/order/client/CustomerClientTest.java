package com.bss.order.client;

import com.sun.net.httpserver.HttpServer;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.web.client.RestClient;

import java.net.InetSocketAddress;
import java.nio.charset.StandardCharsets;
import java.util.UUID;
import java.util.concurrent.atomic.AtomicReference;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

/**
 * Giai đoạn 9 việc 3c (ADR-008 quyết định 4) — CustomerClient gọi customer-service bằng CHÍNH
 * token của khách (không dùng tài khoản dịch vụ quyền rộng). Kiểm bằng 1 HTTP server THẬT của JDK
 * (không mock RestClient): request thật đi qua mạng loopback, server ghi lại header nhận được.
 */
class CustomerClientTest {

    private HttpServer server;
    private final AtomicReference<String> receivedAuth = new AtomicReference<>();
    private volatile int status = 200;
    private volatile String body = "";

    @BeforeEach
    void start() throws Exception {
        server = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0);
        server.createContext("/tmf-api/customerManagement/v4/customer/me", ex -> {
            receivedAuth.set(ex.getRequestHeaders().getFirst("Authorization"));
            byte[] out = body.getBytes(StandardCharsets.UTF_8);
            ex.getResponseHeaders().add("Content-Type", "application/json");
            ex.sendResponseHeaders(status, out.length == 0 ? -1 : out.length);
            if (out.length > 0) ex.getResponseBody().write(out);
            ex.close();
        });
        server.start();
    }

    @AfterEach
    void stop() {
        server.stop(0);
    }

    private CustomerClient client() {
        return new CustomerClient(RestClient.builder(), "http://127.0.0.1:" + server.getAddress().getPort());
    }

    @Test
    void forwards_the_callers_own_bearer_token_and_maps_the_profile() {
        UUID id = UUID.randomUUID();
        body = """
                {"id":"%s","name":"Khach","email":"k@example.com","status":"Active","selfRegistered":true,
                 "phoneNumber":null,"createdAt":"2026-09-28T00:00:00Z","updatedAt":"2026-09-28T00:00:00Z"}
                """.formatted(id);

        var me = client().me("abc.def.ghi");

        assertThat(receivedAuth.get()).isEqualTo("Bearer abc.def.ghi");
        assertThat(me.id()).isEqualTo(id);
        assertThat(me.status()).isEqualTo("Active");
        assertThat(me.isActive()).isTrue();
    }

    @Test
    void no_profile_404_becomes_NoCustomerProfileException() {
        status = 404;
        body = "{\"status\":404}";
        assertThatThrownBy(() -> client().me("t")).isInstanceOf(NoCustomerProfileException.class);
    }

    @Test
    void server_error_becomes_CustomerServiceUnavailableException() {
        status = 500;
        body = "{}";
        assertThatThrownBy(() -> client().me("t")).isInstanceOf(CustomerServiceUnavailableException.class);
    }

    @Test
    void connection_refused_becomes_CustomerServiceUnavailableException() {
        var dead = new CustomerClient(RestClient.builder(), "http://127.0.0.1:1");
        assertThatThrownBy(() -> dead.me("t")).isInstanceOf(CustomerServiceUnavailableException.class);
    }
}
