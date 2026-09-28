package com.bss.product.controller;

import com.bss.product.dto.CreateOfferingRequest;
import com.bss.product.dto.PatchOfferingRequest;
import com.bss.product.dto.ProductOfferingDto;
import com.bss.product.model.LifecycleStatus;
import com.bss.product.security.CallerAccess;
import com.bss.product.service.ProductOfferingService;
import jakarta.validation.Valid;
import org.springframework.http.MediaType;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.*;

import java.net.URI;
import java.util.List;
import java.util.UUID;

/**
 * TMF620 Product Catalog Management — Offering endpoints.
 *   GET    /tmf-api/productCatalog/v4/productOffering        (công khai; khách chỉ thấy gói đang bán)
 *   POST   /tmf-api/productCatalog/v4/productOffering        (admin)
 *   GET    /tmf-api/productCatalog/v4/productOffering/{id}   (công khai; gói đã ngừng bán → 404 với khách)
 *   PATCH  /tmf-api/productCatalog/v4/productOffering/{id}   (admin — sửa giá / ngừng bán; merge-patch)
 *   DELETE /tmf-api/productCatalog/v4/productOffering/{id}   (admin)
 */
@RestController
@RequestMapping("/tmf-api/productCatalog/v4/productOffering")
public class ProductOfferingController {

    private final ProductOfferingService service;
    private final CallerAccess access;

    public ProductOfferingController(ProductOfferingService service, CallerAccess access) {
        this.service = service;
        this.access = access;
    }

    @GetMapping
    public ResponseEntity<List<ProductOfferingDto>> list(
            @RequestParam(required = false) UUID categoryId,
            @RequestParam(required = false) LifecycleStatus lifecycleStatus,
            @RequestParam(defaultValue = "0") int offset,
            @RequestParam(defaultValue = "20") int limit) {

        var page = service.list(categoryId, lifecycleStatus, offset, Math.min(limit, 100),
                !access.seesEntireCatalog());
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
        return service.get(id, !access.seesEntireCatalog());
    }

    @PatchMapping(value = "/{id}",
            consumes = {MediaType.APPLICATION_JSON_VALUE, "application/merge-patch+json"})
    public ProductOfferingDto patch(@PathVariable UUID id, @Valid @RequestBody PatchOfferingRequest req) {
        return service.patch(id, req);
    }

    @DeleteMapping("/{id}")
    public ResponseEntity<Void> delete(@PathVariable UUID id) {
        service.delete(id);
        return ResponseEntity.noContent().build();
    }
}
