package com.bss.product;

import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.testcontainers.service.connection.ServiceConnection;
import org.springframework.test.web.servlet.MockMvc;
import org.testcontainers.containers.PostgreSQLContainer;
import org.testcontainers.junit.jupiter.Container;
import org.testcontainers.junit.jupiter.Testcontainers;

import static org.hamcrest.Matchers.greaterThanOrEqualTo;
import static org.hamcrest.Matchers.notNullValue;
import static org.springframework.http.MediaType.APPLICATION_JSON;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.*;

@SpringBootTest
@AutoConfigureMockMvc
@Testcontainers
class ProductCatalogIT {

    @Container
    @ServiceConnection
    static PostgreSQLContainer<?> postgres = new PostgreSQLContainer<>("postgres:15-alpine");

    @Autowired MockMvc mvc;

    @Test
    void seed_data_loaded_via_flyway() throws Exception {
        mvc.perform(get("/tmf-api/productCatalog/v4/productOffering?limit=10"))
                .andExpect(status().isOk())
                .andExpect(header().string("X-Total-Count", greaterThanOrEqualTo("4")))
                .andExpect(jsonPath("$[0].id", notNullValue()));
    }

    @Test
    void create_and_filter_by_category() throws Exception {
        var body = """
                {
                  "name": "Mega 999",
                  "description": "Test offering",
                  "categoryId": "11111111-1111-1111-1111-111111111111",
                  "priceAmount": 999000,
                  "priceCurrency": "VND",
                  "recurringPeriod": "monthly"
                }
                """;
        mvc.perform(post("/tmf-api/productCatalog/v4/productOffering")
                        .contentType(APPLICATION_JSON)
                        .content(body))
                .andExpect(status().isCreated());

        mvc.perform(get("/tmf-api/productCatalog/v4/productOffering")
                        .param("categoryId", "11111111-1111-1111-1111-111111111111"))
                .andExpect(status().isOk())
                .andExpect(header().string("X-Total-Count", greaterThanOrEqualTo("3")));
    }

    @Test
    void unknown_offering_returns_404() throws Exception {
        mvc.perform(get("/tmf-api/productCatalog/v4/productOffering/{id}",
                        "00000000-0000-0000-0000-000000000000"))
                .andExpect(status().isNotFound());
    }
}
