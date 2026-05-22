package com.bss.product.controller;

import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RestController;

import java.util.Map;

/** Placeholder. Replace with TMF620 ProductCatalogManagement endpoints. */
@RestController
public class HealthController {

    @GetMapping("/tmf-api/productCatalog/v4/catalog")
    public Map<String, Object> listCatalogs() {
        return Map.of("status", "scaffold", "todo", "implement TMF620");
    }
}
