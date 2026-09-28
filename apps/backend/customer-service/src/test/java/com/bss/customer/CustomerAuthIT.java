package com.bss.customer;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ObjectNode;
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

import static org.hamcrest.Matchers.equalTo;
import static org.hamcrest.Matchers.everyItem;
import static org.springframework.http.MediaType.APPLICATION_JSON;
import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.jwt;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.*;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.*;

/**
 * Giai đoạn 9 việc 3 (ADR-008) — luật danh tính & sở hữu của customer-service khi BẬT auth.
 *
 * <p>{@code jwt()} chỉ thay bước "giải mã + kiểm chữ ký" (việc của Keycloak/JWKS, đã kiểm thật ở
 * việc 2). Bộ lọc Spring Security THẬT vẫn chạy và áp luật phân quyền thật; DB là Postgres thật
 * (Testcontainers) — không mock framework (CLAUDE.md §9).
 *
 * <p>{@code jwk-set-uri} trỏ tới cổng không tồn tại: bắt buộc có để context dựng được bean
 * JwtDecoder, nhưng không bao giờ bị gọi vì {@code jwt()} bỏ qua bước giải mã.
 */
@SpringBootTest(properties = {
        "bss.auth.enabled=true",
        "spring.security.oauth2.resourceserver.jwt.jwk-set-uri=http://localhost:1/unused"
})
@AutoConfigureMockMvc
@Testcontainers
class CustomerAuthIT {

    @Container
    @ServiceConnection
    static PostgreSQLContainer<?> postgres = new PostgreSQLContainer<>("postgres:15-alpine");

    static final String BASE = "/tmf-api/customerManagement/v4/customer";

    @Autowired MockMvc mvc;
    @Autowired ObjectMapper json;

    /** Token của 1 khách đã đăng ký Keycloak (role customer), mỗi test 1 sub riêng. */
    static RequestPostProcessor customer(String sub, String email) {
        return jwt().jwt(j -> j.subject(sub).claim("email", email))
                .authorities(new SimpleGrantedAuthority("ROLE_customer"));
    }

    static RequestPostProcessor admin() {
        return jwt().jwt(j -> j.subject("admin-sub").claim("email", "admin1@bss.local"))
                .authorities(new SimpleGrantedAuthority("ROLE_admin"));
    }

    static String uniq() { return UUID.randomUUID().toString(); }

    private String profile(String name, String phone) {
        ObjectNode b = json.createObjectNode().put("name", name);
        if (phone != null) b.put("phoneNumber", phone);
        return b.toString();
    }

    // ---------- Chưa đăng nhập ----------

    @Test
    void no_token_is_401_even_for_list() throws Exception {
        mvc.perform(get(BASE)).andExpect(status().isUnauthorized());
        mvc.perform(get(BASE + "/me")).andExpect(status().isUnauthorized());
    }

    // ---------- Khách tự tạo hồ sơ (/me) ----------

    @Test
    void customer_self_registers_profile_starts_initialized_with_email_from_token() throws Exception {
        String sub = uniq(), email = sub + "@example.com";

        // Chưa có hồ sơ → 404 (web-portal dựa vào đây để hiện form "hoàn tất hồ sơ").
        mvc.perform(get(BASE + "/me").with(customer(sub, email))).andExpect(status().isNotFound());

        mvc.perform(post(BASE + "/me").with(customer(sub, email))
                        .contentType(APPLICATION_JSON).content(profile("Nguyen Van A", "0901234567")))
                .andExpect(status().isCreated())
                .andExpect(jsonPath("$.email", equalTo(email)))       // lấy từ token, không từ body
                .andExpect(jsonPath("$.status", equalTo("Initialized")))
                .andExpect(jsonPath("$.selfRegistered", equalTo(true)));

        mvc.perform(get(BASE + "/me").with(customer(sub, email)))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.name", equalTo("Nguyen Van A")));

        // Tạo lần 2 cho cùng tài khoản → 409, không tạo trùng.
        mvc.perform(post(BASE + "/me").with(customer(sub, email))
                        .contentType(APPLICATION_JSON).content(profile("Lan hai", null)))
                .andExpect(status().isConflict());
    }

    @Test
    void customer_cannot_set_email_or_status_through_me() throws Exception {
        String sub = uniq(), email = sub + "@example.com";
        ObjectNode withStatus = json.createObjectNode().put("name", "Mallory").put("status", "Active");
        mvc.perform(post(BASE + "/me").with(customer(sub, email))
                        .contentType(APPLICATION_JSON).content(withStatus.toString()))
                .andExpect(status().isBadRequest());

        ObjectNode withEmail = json.createObjectNode().put("name", "Mallory").put("email", "khac@example.com");
        mvc.perform(post(BASE + "/me").with(customer(sub, email))
                        .contentType(APPLICATION_JSON).content(withEmail.toString()))
                .andExpect(status().isBadRequest());
    }

    @Test
    void customer_patches_own_name_and_phone_only() throws Exception {
        String sub = uniq(), email = sub + "@example.com";
        mvc.perform(post(BASE + "/me").with(customer(sub, email))
                .contentType(APPLICATION_JSON).content(profile("Ten cu", null))).andExpect(status().isCreated());

        mvc.perform(patch(BASE + "/me").with(customer(sub, email))
                        .contentType("application/merge-patch+json").content(profile("Ten moi", "0912345678")))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.name", equalTo("Ten moi")))
                .andExpect(jsonPath("$.phoneNumber", equalTo("0912345678")))
                .andExpect(jsonPath("$.status", equalTo("Initialized")));

        ObjectNode selfApprove = json.createObjectNode().put("status", "Active");
        mvc.perform(patch(BASE + "/me").with(customer(sub, email))
                        .contentType("application/merge-patch+json").content(selfApprove.toString()))
                .andExpect(status().isBadRequest());
    }

    @Test
    void token_without_email_claim_cannot_create_profile() throws Exception {
        var noEmail = jwt().jwt(j -> j.subject(uniq())).authorities(new SimpleGrantedAuthority("ROLE_customer"));
        mvc.perform(post(BASE + "/me").with(noEmail)
                        .contentType(APPLICATION_JSON).content(profile("Khong email", null)))
                .andExpect(status().isUnprocessableEntity());
    }

    // ---------- Chỉ admin quản lý khách hàng ----------

    @Test
    void customer_role_cannot_list_read_or_modify_other_customers() throws Exception {
        String sub = uniq(), email = sub + "@example.com";
        var me = customer(sub, email);
        mvc.perform(get(BASE).with(me)).andExpect(status().isForbidden());
        mvc.perform(get(BASE + "/{id}", UUID.randomUUID()).with(me)).andExpect(status().isForbidden());
        mvc.perform(post(BASE).with(me).contentType(APPLICATION_JSON)
                .content("{\"name\":\"X\",\"email\":\"x@example.com\"}")).andExpect(status().isForbidden());
        mvc.perform(delete(BASE + "/{id}", UUID.randomUUID()).with(me)).andExpect(status().isForbidden());
    }

    @Test
    void admin_approves_self_registered_customer_and_customer_sees_active() throws Exception {
        String sub = uniq(), email = sub + "@example.com";
        String created = mvc.perform(post(BASE + "/me").with(customer(sub, email))
                        .contentType(APPLICATION_JSON).content(profile("Cho duyet", null)))
                .andExpect(status().isCreated()).andReturn().getResponse().getContentAsString();
        String id = json.readTree(created).get("id").asText();

        // Admin lọc danh sách chờ duyệt.
        mvc.perform(get(BASE + "?status=Initialized&limit=100").with(admin()))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$[*].status", everyItem(equalTo("Initialized"))));

        mvc.perform(patch(BASE + "/{id}", id).with(admin())
                        .contentType("application/merge-patch+json").content("{\"status\":\"Active\"}"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.status", equalTo("Active")));

        mvc.perform(get(BASE + "/me").with(customer(sub, email)))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.status", equalTo("Active")));
    }

    @Test
    void admin_search_matches_name_or_email_case_insensitive() throws Exception {
        String sub = uniq(), email = "timkiem-" + sub + "@example.com";
        mvc.perform(post(BASE + "/me").with(customer(sub, email))
                .contentType(APPLICATION_JSON).content(profile("Tran Thi Tim Kiem", null))).andExpect(status().isCreated());

        mvc.perform(get(BASE + "?q=TIM KIEM").with(admin()))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$[?(@.email == '" + email + "')]").exists());
        mvc.perform(get(BASE + "?q=" + sub.substring(0, 8)).with(admin()))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$[?(@.email == '" + email + "')]").exists());
    }
}
