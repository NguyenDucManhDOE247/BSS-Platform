package com.bss.customer;

import com.bss.customer.model.Customer;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ObjectNode;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.testcontainers.service.connection.ServiceConnection;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.test.web.servlet.MockMvc;
import org.testcontainers.containers.PostgreSQLContainer;
import org.testcontainers.junit.jupiter.Container;
import org.testcontainers.junit.jupiter.Testcontainers;

import static org.hamcrest.Matchers.equalTo;
import static org.hamcrest.Matchers.notNullValue;
import static org.springframework.http.MediaType.APPLICATION_JSON;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.*;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.*;

@SpringBootTest
@AutoConfigureMockMvc
@Testcontainers
class CustomerControllerIT {

    @Container
    @ServiceConnection
    static PostgreSQLContainer<?> postgres = new PostgreSQLContainer<>("postgres:15-alpine");

    @DynamicPropertySource
    static void registerFlyway(DynamicPropertyRegistry r) {
        r.add("spring.flyway.enabled", () -> "true");
    }

    @Autowired MockMvc mvc;
    @Autowired ObjectMapper json;

    @Test
    void create_get_patch_delete() throws Exception {
        // POST
        ObjectNode body = json.createObjectNode()
                .put("name", "Alice")
                .put("email", "alice@example.com");

        var created = mvc.perform(post("/tmf-api/customerManagement/v4/customer")
                        .contentType(APPLICATION_JSON)
                        .content(body.toString()))
                .andExpect(status().isCreated())
                .andExpect(jsonPath("$.id", notNullValue()))
                .andExpect(jsonPath("$.email", equalTo("alice@example.com")))
                // B-15: a brand new customer always starts Initialized — never client-chosen.
                .andExpect(jsonPath("$.status", equalTo("Initialized")))
                .andReturn();

        Customer saved = json.readValue(created.getResponse().getContentAsString(), Customer.class);

        // GET
        mvc.perform(get("/tmf-api/customerManagement/v4/customer/{id}", saved.getId()))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.name", equalTo("Alice")));

        // PATCH — change name only
        ObjectNode patch = json.createObjectNode().put("name", "Alice Pham");
        mvc.perform(patch("/tmf-api/customerManagement/v4/customer/{id}", saved.getId())
                        .contentType("application/merge-patch+json")
                        .content(patch.toString()))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.name", equalTo("Alice Pham")))
                .andExpect(jsonPath("$.email", equalTo("alice@example.com"))); // unchanged

        // DELETE
        mvc.perform(delete("/tmf-api/customerManagement/v4/customer/{id}", saved.getId()))
                .andExpect(status().isNoContent());

        // 404 after delete
        mvc.perform(get("/tmf-api/customerManagement/v4/customer/{id}", saved.getId()))
                .andExpect(status().isNotFound());
    }

    @Test
    void create_rejects_invalid_email() throws Exception {
        ObjectNode body = json.createObjectNode()
                .put("name", "Bob")
                .put("email", "not-an-email");

        mvc.perform(post("/tmf-api/customerManagement/v4/customer")
                        .contentType(APPLICATION_JSON)
                        .content(body.toString()))
                .andExpect(status().isUnprocessableEntity());
    }

    @Test
    void duplicate_email_returns_conflict() throws Exception {
        ObjectNode body = json.createObjectNode()
                .put("name", "Carol")
                .put("email", "carol@example.com");

        mvc.perform(post("/tmf-api/customerManagement/v4/customer")
                        .contentType(APPLICATION_JSON)
                        .content(body.toString()))
                .andExpect(status().isCreated());

        mvc.perform(post("/tmf-api/customerManagement/v4/customer")
                        .contentType(APPLICATION_JSON)
                        .content(body.toString()))
                .andExpect(status().isConflict());
    }

    /**
     * B-15 (mass assignment) regression test. Before the fix, POST bound straight onto the
     * {@code Customer} entity, so this exact request body would create a pre-activated
     * customer (skipping Initialized → Validated → Active) with HTTP 201. Now that POST binds
     * to {@code CreateCustomerRequest} (which has no {@code status} field), Jackson's default
     * "fail on unknown property" rejects it outright.
     */
    @Test
    void create_rejects_client_supplied_status_field() throws Exception {
        ObjectNode body = json.createObjectNode()
                .put("name", "Mallory")
                .put("email", "mallory@example.com")
                .put("status", "Active");

        mvc.perform(post("/tmf-api/customerManagement/v4/customer")
                        .contentType(APPLICATION_JSON)
                        .content(body.toString()))
                .andExpect(status().isBadRequest());
    }

    /**
     * B-15 (pagination) regression test. Before the fix,
     * {@code PageRequest.of(offset / limit, limit, ...)} truncated any offset that wasn't an
     * exact multiple of the page size — {@code offset=1&limit=2} computed page
     * {@code 1/2 = 0} (integer division) and returned records 0–1 again instead of 1–2.
     */
    @Test
    void list_respects_arbitrary_offset() throws Exception {
        for (int i = 0; i < 4; i++) {
            ObjectNode body = json.createObjectNode()
                    .put("name", "Paging" + i)
                    .put("email", "paging" + i + "@example.com");
            mvc.perform(post("/tmf-api/customerManagement/v4/customer")
                            .contentType(APPLICATION_JSON)
                            .content(body.toString()))
                    .andExpect(status().isCreated());
        }

        var firstPage = mvc.perform(get("/tmf-api/customerManagement/v4/customer?offset=0&limit=2"))
                .andExpect(status().isOk())
                .andReturn().getResponse().getContentAsString();

        var secondPage = mvc.perform(get("/tmf-api/customerManagement/v4/customer?offset=1&limit=2"))
                .andExpect(status().isOk())
                .andReturn().getResponse().getContentAsString();

        // offset=1 must NOT equal offset=0 — the pre-fix bug returned the same page for both.
        org.assertj.core.api.Assertions.assertThat(secondPage).isNotEqualTo(firstPage);
    }
}
