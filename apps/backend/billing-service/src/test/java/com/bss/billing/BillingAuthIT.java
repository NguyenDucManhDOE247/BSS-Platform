package com.bss.billing;

import com.bss.billing.listener.OrderCompletedHandler;
import com.bss.billing.repository.BillingAccountRepository;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ObjectNode;
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
import software.amazon.awssdk.services.sqs.SqsClient;

import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.hamcrest.Matchers.*;
import static org.springframework.http.MediaType.APPLICATION_JSON;
import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.jwt;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.*;

/**
 * Giai đoạn 9 việc 3d (ADR-008 quyết định 5) — billing khi BẬT auth: khách chỉ thấy hóa đơn/billing
 * account của CHÍNH mình; chủ sở hữu lấy từ {@code customerSub} trong event OrderCompleted (việc 3c).
 *
 * <p>Hóa đơn được tạo bằng đúng đường thật: {@link OrderCompletedHandler#handle} (bean mà SQS
 * listener gọi) với payload event như order-management phát ra — không insert thẳng vào DB.
 */
@SpringBootTest(properties = {
        "spring.security.oauth2.resourceserver.jwt.jwk-set-uri=http://localhost:1/unused",
        "bss.sqs.consumer.enabled=false"
})
@AutoConfigureMockMvc
@Testcontainers
class BillingAuthIT {

    @Container
    @ServiceConnection
    static PostgreSQLContainer<?> postgres = new PostgreSQLContainer<>("postgres:15-alpine");

    static final String BILLS = "/tmf-api/billingManagement/v4/customerBill";
    static final String ACCOUNTS = "/tmf-api/billingManagement/v4/billingAccount";

    @MockBean SqsClient sqsClient;
    @Autowired OrderCompletedHandler handler;
    @Autowired BillingAccountRepository accounts;
    @Autowired MockMvc mvc;
    @Autowired ObjectMapper json;

    static RequestPostProcessor customer(String sub) {
        return jwt().jwt(j -> j.subject(sub)).authorities(new SimpleGrantedAuthority("ROLE_customer"));
    }

    static RequestPostProcessor admin() {
        return jwt().jwt(j -> j.subject("admin-sub")).authorities(new SimpleGrantedAuthority("ROLE_admin"));
    }

    /** Mô phỏng 1 event OrderCompleted thật đi vào billing (qua đúng bean SQS listener dùng). */
    void orderCompleted(UUID customerId, String customerSub, String amount) {
        ObjectNode detail = json.createObjectNode()
                .put("eventId", UUID.randomUUID().toString())
                .put("orderId", UUID.randomUUID().toString())
                .put("customerId", customerId.toString())
                .put("amount", amount)
                .put("currency", "VND")
                .put("completedAt", "2026-09-28T00:00:00Z");
        if (customerSub != null) detail.put("customerSub", customerSub);
        handler.handle(detail.get("eventId").asText(), "OrderCompleted", detail);
    }

    String firstInvoiceId(RequestPostProcessor who) throws Exception {
        String res = mvc.perform(get(BILLS).with(who)).andExpect(status().isOk())
                .andReturn().getResponse().getContentAsString();
        return json.readTree(res).get(0).get("id").asText();
    }

    @Test
    void no_token_is_401() throws Exception {
        mvc.perform(get(BILLS)).andExpect(status().isUnauthorized());
        mvc.perform(get(ACCOUNTS)).andExpect(status().isUnauthorized());
    }

    @Test
    void customers_see_only_their_own_invoices_and_account_admin_sees_all() throws Exception {
        String subA = UUID.randomUUID().toString(), subB = UUID.randomUUID().toString();
        UUID custA = UUID.randomUUID(), custB = UUID.randomUUID();
        orderCompleted(custA, subA, "100000");
        orderCompleted(custB, subB, "200000");

        // A: chỉ hóa đơn của A — truyền customerId của B cũng không đổi được gì.
        mvc.perform(get(BILLS + "?customerId=" + custB).with(customer(subA)))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$", hasSize(1)))
                .andExpect(jsonPath("$[0].amount", equalTo(110000.0)))  // 100000 + VAT 10%
                .andExpect(header().string("X-Total-Count", "1"));

        String invoiceB = firstInvoiceId(customer(subB));
        mvc.perform(get(BILLS + "/{id}", invoiceB).with(customer(subA))).andExpect(status().isNotFound());
        mvc.perform(get(BILLS + "/{id}", invoiceB).with(customer(subB))).andExpect(status().isOk());

        // Billing account: A chỉ thấy account của A; đọc account của B → 404.
        mvc.perform(get(ACCOUNTS).with(customer(subA)))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$", hasSize(1)))
                .andExpect(jsonPath("$[0].customerId", equalTo(custA.toString())));
        UUID accountB = accounts.findByCustomerId(custB).orElseThrow().getId();
        mvc.perform(get(ACCOUNTS + "/{id}", accountB).with(customer(subA))).andExpect(status().isNotFound());

        // Admin: thấy tất cả, lọc được theo khách, đọc được mọi hóa đơn.
        mvc.perform(get(BILLS + "?limit=100").with(admin()))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$[*].id", hasItem(invoiceB)));
        mvc.perform(get(BILLS + "?customerId=" + custB).with(admin()))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$", hasSize(1)))
                .andExpect(jsonPath("$[0].id", equalTo(invoiceB)));
        mvc.perform(get(BILLS + "/{id}", invoiceB).with(admin())).andExpect(status().isOk());
    }

    @Test
    void event_without_customerSub_is_visible_to_admin_only_then_backfilled_by_later_event() throws Exception {
        String sub = UUID.randomUUID().toString();
        UUID cust = UUID.randomUUID();

        orderCompleted(cust, null, "50000"); // đơn tạo lúc auth tắt / trước GĐ9 — không có chủ
        mvc.perform(get(BILLS).with(customer(sub))).andExpect(status().isOk()).andExpect(jsonPath("$", hasSize(0)));

        orderCompleted(cust, sub, "60000"); // đơn sau có chủ → gắn chủ cho account (1 khách 1 account)
        assertThat(accounts.findByCustomerId(cust).orElseThrow().getOwnerSub()).isEqualTo(sub);
        mvc.perform(get(BILLS).with(customer(sub)))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$", hasSize(2)));
    }

    /**
     * Giai đoạn 9 việc 5: doanh thu cho Dashboard admin-console. Cộng ở trình duyệt từ 1 trang danh sách
     * sẽ sai ngay khi có nhiều hơn 1 trang → tổng phải tính ở DB.
     */
    @Test
    void revenue_summary_is_admin_only_and_sums_every_invoice() throws Exception {
        String before = mvc.perform(get(BILLS + "/summary").with(admin()))
                .andExpect(status().isOk()).andReturn().getResponse().getContentAsString();
        long countBefore = json.readTree(before).get("invoiceCount").asLong();
        double totalBefore = json.readTree(before).get("totalAmount").asDouble();

        orderCompleted(UUID.randomUUID(), UUID.randomUUID().toString(), "100000"); // → 110000 gồm VAT
        orderCompleted(UUID.randomUUID(), UUID.randomUUID().toString(), "50000");  // → 55000

        mvc.perform(get(BILLS + "/summary").with(admin()))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.invoiceCount", equalTo((int) countBefore + 2)))
                .andExpect(jsonPath("$.totalAmount", closeTo(totalBefore + 165000.0, 0.001)))
                .andExpect(jsonPath("$.currency", equalTo("VND")));

        mvc.perform(get(BILLS + "/summary").with(customer(UUID.randomUUID().toString())))
                .andExpect(status().isForbidden());
    }

    @Test
    void only_admin_opens_billing_accounts_manually() throws Exception {
        String body = "{\"customerId\":\"" + UUID.randomUUID() + "\",\"name\":\"Tai khoan\"}";
        mvc.perform(post(ACCOUNTS).with(customer(UUID.randomUUID().toString()))
                .contentType(APPLICATION_JSON).content(body)).andExpect(status().isForbidden());
        mvc.perform(post(ACCOUNTS).with(admin())
                .contentType(APPLICATION_JSON).content(body)).andExpect(status().isCreated());
    }
}
