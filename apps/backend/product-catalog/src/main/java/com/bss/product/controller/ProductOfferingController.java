package com.bss.product.controller;

import com.bss.product.dto.CreateOfferingRequest;
import com.bss.product.dto.ProductOfferingDto;
import com.bss.product.model.LifecycleStatus;
import com.bss.product.service.ProductOfferingService;
import jakarta.validation.Valid;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.*;

import java.net.URI;
import java.util.List;
import java.util.UUID;

/**
 * TMF620 Product Catalog Management — Offering endpoints.
 *   GET    /tmf-api/productCatalog/v4/productOffering
 *   POST   /tmf-api/productCatalog/v4/productOffering
 *   GET    /tmf-api/productCatalog/v4/productOffering/{id}
 *   DELETE /tmf-api/productCatalog/v4/productOffering/{id}
 */
@RestController
@RequestMapping("/tmf-api/productCatalog/v4/productOffering")
public class ProductOfferingController {

    private final ProductOfferingService service;

    public ProductOfferingController(ProductOfferingService service) {
        this.service = service;
    }

    @GetMapping
    public ResponseEntity<List<ProductOfferingDto>> list(
            @RequestParam(required = false) UUID categoryId,
            @RequestParam(required = false) LifecycleStatus lifecycleStatus,
            @RequestParam(defaultValue = "0") int offset,
            @RequestParam(defaultValue = "20") int limit) {

        var page = service.list(categoryId, lifecycleStatus, offset, Math.min(limit, 100));
        return ResponseEntity.ok()
                .header("X-Total-Count", String.valueOf(page.getTotalElements()))
                .body(page.getContent());
    }

    @PostMapping
    public ResponseEntity<ProductOfferingDto> create(@Valid @RequestBody CreateOfferingRequest req) {
        var created = service.create(req);
        return ResponseEntity
                .created(URI.create("/tmf-api/productCatalog/v4/productOffering/" + created.id()))
                .body(created);
    }

    @GetMapping("/{id}")
    public ProductOfferingDto get(@PathVariable UUID id) {
        return service.get(id);
    }

    @DeleteMapping("/{id}")
    public ResponseEntity<Void> delete(@PathVariable UUID id) {
        service.delete(id);
        return ResponseEntity.noContent().build();
    }
}
