package com.bss.customer.controller;

import com.bss.customer.dto.CreateCustomerRequest;
import com.bss.customer.dto.MyProfileRequest;
import com.bss.customer.dto.PatchCustomerRequest;
import com.bss.customer.model.Customer;
import com.bss.customer.model.Customer.CustomerStatus;
import com.bss.customer.security.CurrentUser;
import com.bss.customer.service.CustomerService;
import jakarta.validation.Valid;
import org.springframework.http.MediaType;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.*;

import java.net.URI;
import java.util.List;
import java.util.UUID;

/**
 * TMF629 Customer Management.
 *   GET    /tmf-api/customerManagement/v4/customer?status=&q=&offset=&limit=   (admin)
 *   POST   /tmf-api/customerManagement/v4/customer                          (admin)
 *   GET    /tmf-api/customerManagement/v4/customer/{id}                     (admin)
 *   PATCH  /tmf-api/customerManagement/v4/customer/{id}     (application/merge-patch+json, admin — duyệt/khóa)
 *   DELETE /tmf-api/customerManagement/v4/customer/{id}                     (admin)
 *
 * Giai đoạn 9 (ADR-008) — khách hàng tự quản lý hồ sơ của CHÍNH mình (role customer):
 *   GET    /tmf-api/customerManagement/v4/customer/me
 *   POST   /tmf-api/customerManagement/v4/customer/me
 *   PATCH  /tmf-api/customerManagement/v4/customer/me
 *
 * Phân quyền nằm ở SecurityConfig. "/me" là path cố định nên Spring ưu tiên nó hơn "/{id}".
 */
@RestController
@RequestMapping("/tmf-api/customerManagement/v4/customer")
public class CustomerController {

    private final CustomerService service;
    private final CurrentUser currentUser;

    public CustomerController(CustomerService service, CurrentUser currentUser) {
        this.service = service;
        this.currentUser = currentUser;
    }

    @GetMapping
    public ResponseEntity<List<Customer>> list(
            @RequestParam(defaultValue = "0") int offset,
            @RequestParam(defaultValue = "20") int limit,
            @RequestParam(required = false) CustomerStatus status,
            @RequestParam(required = false) String q) {
        var page = service.list(offset, Math.min(limit, 100), status, q);
        return ResponseEntity.ok()
                .header("X-Total-Count", String.valueOf(page.getTotalElements()))
                .body(page.getContent());
    }

    @PostMapping
    public ResponseEntity<Customer> create(@Valid @RequestBody CreateCustomerRequest req) {
        var saved = service.create(req);
        return ResponseEntity
                .created(URI.create("/tmf-api/customerManagement/v4/customer/" + saved.getId()))
                .body(saved);
    }

    // ---------- /me — phải khai TRƯỚC /{id} cho dễ đọc (Spring vẫn ưu tiên path cố định) ----------

    @GetMapping("/me")
    public Customer getMine() {
        return service.getMine(currentUser.subject());
    }

    @PostMapping("/me")
    public ResponseEntity<Customer> createMine(@RequestBody MyProfileRequest req) {
        var saved = service.createMine(currentUser.subject(), currentUser.email(), req);
        return ResponseEntity
                .created(URI.create("/tmf-api/customerManagement/v4/customer/me"))
                .body(saved);
    }

    @PatchMapping(value = "/me",
            consumes = {MediaType.APPLICATION_JSON_VALUE, "application/merge-patch+json"})
    public Customer patchMine(@RequestBody MyProfileRequest req) {
        return service.patchMine(currentUser.subject(), req);
    }

    // ---------- admin ----------

    @GetMapping("/{id}")
    public Customer get(@PathVariable UUID id) {
        return service.get(id);
    }

    @PatchMapping(value = "/{id}",
            consumes = {MediaType.APPLICATION_JSON_VALUE, "application/merge-patch+json"})
    public Customer patch(@PathVariable UUID id, @Valid @RequestBody PatchCustomerRequest req) {
        return service.patch(id, req);
    }

    @DeleteMapping("/{id}")
    public ResponseEntity<Void> delete(@PathVariable UUID id) {
        service.delete(id);
        return ResponseEntity.noContent().build();
    }
}
