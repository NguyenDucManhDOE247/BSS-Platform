package com.bss.product;

import com.fasterxml.jackson.databind.ObjectMapper;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.testcontainers.service.connection.ServiceConnection;
import org.springframework.security.core.authority.SimpleGrantedAuthority;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.test.web.servlet.request.RequestPostProcessor;
import org.testcontainers.containers.PostgreSQLContainer;
import org.testcontainers.junit.jupiter.Container;
import org.testcontainers.junit.jupiter.Testcontainers;

import java.util.UUID;

import static org.hamcrest.Matchers.*;
import static org.springframework.http.MediaType.APPLICATION_JSON;
import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.jwt;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.*;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.*;

/**
 * Giai đoạn 9 việc 3b (ADR-008 quyết định 5) — product-catalog khi BẬT auth:
 * duyệt gói công khai nhưng khách CHỈ thấy gói đang bán; mọi thao tác ghi chỉ admin; admin sửa giá /
 * ngừng bán bằng PATCH. {@code jwt()} thay bước giải mã token — bộ lọc Spring Security thật vẫn
 * chạy, DB là Postgres thật (Testcontainers).
 */
@SpringBootTest(properties = {
        "spring.security.oauth2.resourceserver.jwt.jwk-set-uri=http://localhost:1/unused"
})
@AutoConfigureMockMvc
@Testcontainers
class ProductCatalogAuthIT {

    @Container
    @ServiceConnection
    static PostgreSQLContainer<?> postgres = new PostgreSQLContainer<>("postgres:15-alpine");

    static final String BASE = "/tmf-api/productCatalog/v4/productOffering";

    @Autowired MockMvc mvc;
    @Autowired ObjectMapper json;

    static RequestPostProcessor admin() {
        return jwt().jwt(j -> j.subject("admin-sub")).authorities(new SimpleGrantedAuthority("ROLE_admin"));
    }

    static RequestPostProcessor customer() {
        return jwt().jwt(j -> j.subject("cust-sub")).authorities(new SimpleGrantedAuthority("ROLE_customer"));
    }

    private String createAsAdmin(String name, int price) throws Exception {
        String body = """
                {"name":"%s","description":"test","priceAmount":%d,"priceCurrency":"VND","recurringPeriod":"monthly"}
                """.formatted(name, price);
        String res = mvc.perform(post(BASE).with(admin()).contentType(APPLICATION_JSON).content(body))
                .andExpect(status().isCreated()).andReturn().getResponse().getContentAsString();
        return json.readTree(res).get("id").asText();
    }

    private void retire(String id) throws Exception {
        mvc.perform(patch(BASE + "/{id}", id).with(admin())
                        .contentType("application/merge-patch+json").content("{\"lifecycleStatus\":\"Retired\"}"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.lifecycleStatus", equalTo("Retired")));
    }

    // ---------- Ghi: chỉ admin ----------

    @Test
    void anonymous_cannot_write_401_and_customer_cannot_write_403() throws Exception {
        String body = "{\"name\":\"Hack\",\"priceAmount\":1}";
        mvc.perform(post(BASE).contentType(APPLICATION_JSON).content(body)).andExpect(status().isUnauthorized());
        mvc.perform(post(BASE).with(customer()).contentType(APPLICATION_JSON).content(body)).andExpect(status().isForbidden());
        String id = createAsAdmin("Bao ve " + UUID.randomUUID(), 50000);
        mvc.perform(patch(BASE + "/{id}", id).with(customer())
                .contentType("application/merge-patch+json").content("{\"priceAmount\":1}")).andExpect(status().isForbidden());
        mvc.perform(delete(BASE + "/{id}", id).with(customer())).andExpect(status().isForbidden());
    }

    // ---------- Admin sửa giá / ngừng bán ----------

    @Test
    void admin_patches_price_and_description_only_touched_fields_change() throws Exception {
        String id = createAsAdmin("Doi gia " + UUID.randomUUID(), 99000);
        mvc.perform(patch(BASE + "/{id}", id).with(admin())
                        .contentType("application/merge-patch+json").content("{\"priceAmount\":129000}"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.priceAmount", equalTo(129000)))
                .andExpect(jsonPath("$.description", equalTo("test")))   // không gửi → giữ nguyên
                .andExpect(jsonPath("$.lifecycleStatus", equalTo("Active")));
    }

    @Test
    void admin_patch_rejects_negative_price() throws Exception {
        String id = createAsAdmin("Gia am " + UUID.randomUUID(), 10000);
        mvc.perform(patch(BASE + "/{id}", id).with(admin())
                        .contentType("application/merge-patch+json").content("{\"priceAmount\":-1}"))
                .andExpect(status().isUnprocessableEntity());
    }

    @Test
    void patch_unknown_offering_is_404() throws Exception {
        mvc.perform(patch(BASE + "/{id}", UUID.randomUUID()).with(admin())
                        .contentType("application/merge-patch+json").content("{\"priceAmount\":1}"))
                .andExpect(status().isNotFound());
    }

    // ---------- Khách chỉ thấy gói đang bán ----------

    @Test
    void retired_offering_hidden_from_customers_and_anonymous_but_visible_to_admin() throws Exception {
        String name = "Ngung ban " + UUID.randomUUID();
        String id = createAsAdmin(name, 77000);
        retire(id);

        // Danh sách: khách/ẩn danh không thấy gói Retired, kể cả khi CỐ Ý lọc lifecycleStatus=Retired.
        mvc.perform(get(BASE + "?limit=100"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$[*].id", not(hasItem(id))))
                .andExpect(jsonPath("$[*].lifecycleStatus", everyItem(anyOf(equalTo("Active"), equalTo("Launched")))));
        mvc.perform(get(BASE + "?lifecycleStatus=Retired&limit=100").with(customer()))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$[*].id", not(hasItem(id))));

        // Chi tiết: 404 với khách (web-portal/order-management không mua được gói đã ngừng bán).
        mvc.perform(get(BASE + "/{id}", id)).andExpect(status().isNotFound());
        mvc.perform(get(BASE + "/{id}", id).with(customer())).andExpect(status().isNotFound());

        // Admin vẫn thấy + lọc được.
        mvc.perform(get(BASE + "/{id}", id).with(admin())).andExpect(status().isOk());
        mvc.perform(get(BASE + "?lifecycleStatus=Retired&limit=100").with(admin()))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$[*].id", hasItem(id)));
    }

    @Test
    void anonymous_can_browse_active_offerings() throws Exception {
        mvc.perform(get(BASE)).andExpect(status().isOk()).andExpect(jsonPath("$[0].id", notNullValue()));
        mvc.perform(get("/tmf-api/productCatalog/v4/category")).andExpect(status().isOk());
    }
}
