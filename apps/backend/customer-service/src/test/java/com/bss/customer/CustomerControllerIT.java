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
                .put("email", "alice@example.com")
                .put("status", "Active");

        var created = mvc.perform(post("/tmf-api/customerManagement/v4/customer")
                        .contentType(APPLICATION_JSON)
                        .content(body.toString()))
                .andExpect(status().isCreated())
                .andExpect(jsonPath("$.id", notNullValue()))
                .andExpect(jsonPath("$.email", equalTo("alice@example.com")))
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
}
