package com.bss.order;

import com.bss.order.client.CustomerClient;
import com.bss.order.client.CustomerServiceUnavailableException;
import com.bss.order.client.CustomerSnapshot;
import com.bss.order.client.NoCustomerProfileException;
import com.bss.order.client.OfferingSnapshot;
import com.bss.order.client.ProductCatalogClient;
import com.bss.order.model.EventOutbox;
import com.bss.order.repository.EventOutboxRepository;
import com.fasterxml.jackson.databind.ObjectMapper;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.test.mock.mockito.MockBean;
import org.springframework.boot.testcontainers.service.connection.ServiceConnection;
import org.springframework.security.core.authority.SimpleGrantedAuthority;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.test.web.servlet.request.RequestPostProcessor;
import org.testcontainers.containers.PostgreSQLContainer;
import org.testcontainers.junit.jupiter.Container;
import org.testcontainers.junit.jupiter.Testcontainers;
import software.amazon.awssdk.services.eventbridge.EventBridgeClient;

import java.math.BigDecimal;
import java.util.ArrayList;
import java.util.List;
import java.util.UUID;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import java.util.concurrent.TimeUnit;

import static org.assertj.core.api.Assertions.assertThat;
import static org.hamcrest.Matchers.*;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.times;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;
import static org.springframework.http.MediaType.APPLICATION_JSON;
import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.jwt;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.*;

/**
 * Giai đoạn 9 việc 3c (ADR-008 quyết định 3, 4, 5) — order-management khi BẬT auth.
 *
 * <p>2 client HTTP của CHÍNH repo này (customer-service, product-catalog) được stub bằng
 * {@code @MockBean} — cùng cách OrderServiceIT đã stub ProductCatalogClient từ B-13. Không mock
 * framework: Spring Security, JPA, Postgres (Testcontainers) đều là thật. Việc chuyển tiếp token
 * sang customer-service có test riêng bằng HTTP server thật ({@code CustomerClientTest}).
 */
@SpringBootTest(properties = {
        "spring.security.oauth2.resourceserver.jwt.jwk-set-uri=http://localhost:1/unused",
        "bss.outbox.publisher.enabled=false"
})
@AutoConfigureMockMvc
@Testcontainers
class OrderAuthIT {

    @Container
    @ServiceConnection
    static PostgreSQLContainer<?> postgres = new PostgreSQLContainer<>("postgres:15-alpine");

    static final String BASE = "/tmf-api/orderManagement/v4/productOrder";
    static final UUID OFFERING = UUID.randomUUID();

    @MockBean EventBridgeClient eventBridgeClient;
    @MockBean ProductCatalogClient catalog;
    @MockBean CustomerClient customers;

    @Autowired MockMvc mvc;
    @Autowired ObjectMapper json;
    @Autowired EventOutboxRepository outbox;

    @BeforeEach
    void catalogSellsOneOffering() {
        when(catalog.getOffering(OFFERING)).thenReturn(
                new OfferingSnapshot(OFFERING, "Pro 80", "Active", new BigDecimal("199000"), "VND"));
    }

    static RequestPostProcessor customer(String sub) {
        return jwt().jwt(j -> j.subject(sub)).authorities(new SimpleGrantedAuthority("ROLE_customer"));
    }

    static RequestPostProcessor admin() {
        return jwt().jwt(j -> j.subject("admin-sub")).authorities(new SimpleGrantedAuthority("ROLE_admin"));
    }

    /** Khách có hồ sơ ở customer-service với trạng thái cho trước. */
    UUID givenProfile(String sub, String status) {
        UUID customerId = UUID.randomUUID();
        when(customers.me(eq("token-" + sub)))
                .thenReturn(new CustomerSnapshot(customerId, status, sub + "@example.com"));
        return customerId;
    }

    /** customerIdInBody = null → không gửi trường customerId (đúng cách web-portal mới sẽ gửi). */
    static String orderBody(UUID customerIdInBody) {
        String cid = customerIdInBody == null ? "" : "\"customerId\":\"" + customerIdInBody + "\",";
        return """
                {%s"category":"new","description":"Dang ky",
                 "items":[{"productOfferingId":"%s","quantity":1}]}
                """.formatted(cid, OFFERING);
    }

    /** jwt() không mang token thô — tự đặt tokenValue để kiểm order-management chuyển tiếp ĐÚNG token. */
    static RequestPostProcessor customerWithToken(String sub) {
        return jwt().jwt(j -> j.subject(sub).tokenValue("token-" + sub))
                .authorities(new SimpleGrantedAuthority("ROLE_customer"));
    }

    // ---------- Ai được đặt hàng ----------

    @Test
    void no_token_401_and_admin_cannot_place_orders_403() throws Exception {
        mvc.perform(post(BASE).contentType(APPLICATION_JSON).content(orderBody(UUID.randomUUID())))
                .andExpect(status().isUnauthorized());
        mvc.perform(post(BASE).with(admin()).contentType(APPLICATION_JSON).content(orderBody(UUID.randomUUID())))
                .andExpect(status().isForbidden());
    }

    @Test
    void active_customer_orders_customerId_comes_from_profile_not_body_and_owner_is_stamped() throws Exception {
        String sub = UUID.randomUUID().toString();
        UUID realCustomerId = givenProfile(sub, "Active");
        UUID someoneElse = UUID.randomUUID(); // cố tình gửi id của người khác trong body

        String res = mvc.perform(post(BASE).with(customerWithToken(sub))
                        .contentType(APPLICATION_JSON).content(orderBody(someoneElse)))
                .andExpect(status().isCreated())
                .andExpect(jsonPath("$.customerId", equalTo(realCustomerId.toString())))
                .andExpect(jsonPath("$.totalAmount", equalTo(199000)))
                .andReturn().getResponse().getContentAsString();
        UUID orderId = UUID.fromString(json.readTree(res).get("id").asText());
        assertThat(orderId.version()).as("B-15: PK là UUID v7 (bss-common-java UuidV7Generator)").isEqualTo(7);

        // Event mang customerSub để billing đóng dấu chủ sở hữu lên hóa đơn (ADR-008 quyết định 5).
        EventOutbox row = outbox.findAll().stream()
                .filter(e -> e.getAggregateId().equals(orderId)).findFirst().orElseThrow();
        var payload = json.readTree(row.getPayload());
        assertThat(payload.get("customerSub").asText()).isEqualTo(sub);
        assertThat(row.getId().version()).as("id outbox = khóa chống trùng B-11, giờ là v7").isEqualTo(7);
        assertThat(payload.get("customerId").asText()).isEqualTo(realCustomerId.toString());
    }

    @Test
    void customer_not_yet_approved_gets_422_with_clear_reason() throws Exception {
        String sub = UUID.randomUUID().toString();
        givenProfile(sub, "Initialized");
        mvc.perform(post(BASE).with(customerWithToken(sub)).contentType(APPLICATION_JSON).content(orderBody(null)))
                .andExpect(status().isUnprocessableEntity())
                .andExpect(jsonPath("$.detail", containsString("duyệt")));
    }

    @Test
    void customer_without_profile_gets_422() throws Exception {
        String sub = UUID.randomUUID().toString();
        when(customers.me(eq("token-" + sub))).thenThrow(new NoCustomerProfileException());
        mvc.perform(post(BASE).with(customerWithToken(sub)).contentType(APPLICATION_JSON).content(orderBody(null)))
                .andExpect(status().isUnprocessableEntity())
                .andExpect(jsonPath("$.detail", containsString("hồ sơ")));
    }

    @Test
    void customer_service_down_is_503_not_500() throws Exception {
        String sub = UUID.randomUUID().toString();
        when(customers.me(any())).thenThrow(new CustomerServiceUnavailableException(new RuntimeException("down")));
        mvc.perform(post(BASE).with(customerWithToken(sub)).contentType(APPLICATION_JSON).content(orderBody(null)))
                .andExpect(status().isServiceUnavailable())
                .andExpect(jsonPath("$.detail", containsString("customer-service")));
    }

    // ---------- Quyền sở hữu khi ĐỌC ----------

    @Test
    void customers_see_only_their_own_orders_admin_sees_all() throws Exception {
        String subA = UUID.randomUUID().toString(), subB = UUID.randomUUID().toString();
        UUID custA = givenProfile(subA, "Active");
        givenProfile(subB, "Active");

        String a = mvc.perform(post(BASE).with(customerWithToken(subA)).contentType(APPLICATION_JSON).content(orderBody(null)))
                .andExpect(status().isCreated()).andReturn().getResponse().getContentAsString();
        String orderA = json.readTree(a).get("id").asText();
        mvc.perform(post(BASE).with(customerWithToken(subB)).contentType(APPLICATION_JSON).content(orderBody(null)))
                .andExpect(status().isCreated());

        // A thấy đơn của mình; truyền customerId của người khác cũng không đổi được gì.
        mvc.perform(get(BASE + "?customerId=" + UUID.randomUUID()).with(customer(subA)))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$", hasSize(1)))
                .andExpect(jsonPath("$[0].id", equalTo(orderA)));

        // B đọc đơn của A theo id → 404 (không lộ việc id đó tồn tại).
        mvc.perform(get(BASE + "/{id}", orderA).with(customer(subB))).andExpect(status().isNotFound());
        mvc.perform(get(BASE + "/{id}", orderA).with(customer(subA))).andExpect(status().isOk());

        // Admin thấy tất cả, lọc được theo khách.
        mvc.perform(get(BASE + "?limit=100").with(admin()))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$[*].id", hasItem(orderA)));
        mvc.perform(get(BASE + "?customerId=" + custA).with(admin()))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$[*].customerId", everyItem(equalTo(custA.toString()))));
        mvc.perform(get(BASE + "/{id}", orderA).with(admin())).andExpect(status().isOk());

        mvc.perform(get(BASE)).andExpect(status().isUnauthorized());
    }

    // ---------- B-15: Idempotency-Key ----------

    static String orderBodyQty(int quantity) {
        return """
                {"category":"new","description":"Dang ky","items":[{"productOfferingId":"%s","quantity":%d}]}
                """.formatted(OFFERING, quantity);
    }

    long ordersOf(String sub) throws Exception {
        String res = mvc.perform(get(BASE + "?limit=100").with(customer(sub)))
                .andExpect(status().isOk()).andReturn().getResponse().getContentAsString();
        return json.readTree(res).size();
    }

    @Test
    void same_idempotency_key_twice_creates_one_order_and_replays_it() throws Exception {
        String sub = UUID.randomUUID().toString();
        givenProfile(sub, "Active");

        String first = mvc.perform(post(BASE).with(customerWithToken(sub)).header("Idempotency-Key", "dbl-click-1")
                        .contentType(APPLICATION_JSON).content(orderBodyQty(1)))
                .andExpect(status().isCreated())
                .andExpect(header().doesNotExist("Idempotent-Replayed"))
                .andReturn().getResponse().getContentAsString();
        String orderId = json.readTree(first).get("id").asText();

        // Bấm lần 2 (hoặc trình duyệt tự gửi lại): cùng đơn, cùng 201, có dấu replayed — không đơn mới.
        mvc.perform(post(BASE).with(customerWithToken(sub)).header("Idempotency-Key", "dbl-click-1")
                        .contentType(APPLICATION_JSON).content(orderBodyQty(1)))
                .andExpect(status().isCreated())
                .andExpect(header().string("Idempotent-Replayed", "true"))
                .andExpect(header().string("Location", endsWith(orderId)))
                .andExpect(jsonPath("$.id", equalTo(orderId)));

        assertThat(ordersOf(sub)).isEqualTo(1);
        assertThat(outbox.findAll().stream().filter(e -> e.getAggregateId().toString().equals(orderId))).hasSize(1);
        // Lần replay không gọi lại customer-service / catalog.
        verify(customers, times(1)).me("token-" + sub);
    }

    @Test
    void same_key_with_different_body_is_422_and_creates_nothing() throws Exception {
        String sub = UUID.randomUUID().toString();
        givenProfile(sub, "Active");
        mvc.perform(post(BASE).with(customerWithToken(sub)).header("Idempotency-Key", "k-1")
                        .contentType(APPLICATION_JSON).content(orderBodyQty(1)))
                .andExpect(status().isCreated());

        mvc.perform(post(BASE).with(customerWithToken(sub)).header("Idempotency-Key", "k-1")
                        .contentType(APPLICATION_JSON).content(orderBodyQty(2)))
                .andExpect(status().isUnprocessableEntity())
                .andExpect(jsonPath("$.detail", containsString("key mới")));
        assertThat(ordersOf(sub)).isEqualTo(1);
    }

    @Test
    void keys_are_scoped_per_user_and_requests_without_a_key_are_not_deduplicated() throws Exception {
        String subA = UUID.randomUUID().toString(), subB = UUID.randomUUID().toString();
        givenProfile(subA, "Active");
        givenProfile(subB, "Active");
        for (String sub : new String[]{subA, subB}) {
            mvc.perform(post(BASE).with(customerWithToken(sub)).header("Idempotency-Key", "shared-key")
                            .contentType(APPLICATION_JSON).content(orderBodyQty(1)))
                    .andExpect(status().isCreated())
                    .andExpect(header().doesNotExist("Idempotent-Replayed"));
        }
        assertThat(ordersOf(subA)).isEqualTo(1);
        assertThat(ordersOf(subB)).isEqualTo(1);

        // Không có header → hành vi cũ: mỗi request một đơn.
        for (int i = 0; i < 2; i++) {
            mvc.perform(post(BASE).with(customerWithToken(subA)).contentType(APPLICATION_JSON).content(orderBodyQty(1)))
                    .andExpect(status().isCreated());
        }
        assertThat(ordersOf(subA)).isEqualTo(3);
    }

    @Test
    void malformed_key_is_400() throws Exception {
        String sub = UUID.randomUUID().toString();
        givenProfile(sub, "Active");
        for (String bad : new String[]{"has space", "x".repeat(256)}) {
            mvc.perform(post(BASE).with(customerWithToken(sub)).header("Idempotency-Key", bad)
                            .contentType(APPLICATION_JSON).content(orderBodyQty(1)))
                    .andExpect(status().isBadRequest());
        }
        assertThat(ordersOf(sub)).isZero();
    }

    /**
     * Race thật, không trông may rủi: latch giữ CẢ HAI request ở customers.me() — tức là sau khi cả hai
     * đã tra key và không thấy gì — rồi thả cùng lúc. Cả hai tạo đơn; PRIMARY KEY (owner_sub, idem_key)
     * để đúng một bên commit, bên kia rollback toàn bộ đơn + outbox của nó và nhận 409.
     */
    @Test
    void concurrent_duplicates_create_exactly_one_order() throws Exception {
        String sub = UUID.randomUUID().toString();
        UUID customerId = UUID.randomUUID();
        var bothInside = new CountDownLatch(2);
        when(customers.me(eq("token-" + sub))).thenAnswer(inv -> {
            bothInside.countDown();
            assertThat(bothInside.await(20, TimeUnit.SECONDS)).as("request thứ 2 không tới kịp").isTrue();
            return new CustomerSnapshot(customerId, "Active", sub + "@example.com");
        });

        var pool = Executors.newFixedThreadPool(2);
        try {
            List<Future<Integer>> results = new ArrayList<>();
            for (int i = 0; i < 2; i++) {
                results.add(pool.submit(() -> mvc.perform(post(BASE).with(customerWithToken(sub))
                                .header("Idempotency-Key", "race-1")
                                .contentType(APPLICATION_JSON).content(orderBodyQty(1)))
                        .andReturn().getResponse().getStatus()));
            }
            var statuses = new ArrayList<Integer>();
            for (var r : results) {
                statuses.add(r.get(60, TimeUnit.SECONDS));
            }
            assertThat(statuses).containsExactlyInAnyOrder(201, 409);
        } finally {
            pool.shutdownNow();
        }
        assertThat(ordersOf(sub)).isEqualTo(1);

        // Gửi lại sau 409 → nhận đúng đơn đã thắng.
        mvc.perform(post(BASE).with(customerWithToken(sub)).header("Idempotency-Key", "race-1")
                        .contentType(APPLICATION_JSON).content(orderBodyQty(1)))
                .andExpect(status().isCreated())
                .andExpect(header().string("Idempotent-Replayed", "true"));
    }
}
