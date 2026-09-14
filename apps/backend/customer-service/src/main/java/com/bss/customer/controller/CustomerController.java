package com.bss.customer.controller;

import com.bss.customer.dto.CreateCustomerRequest;
import com.bss.customer.dto.PatchCustomerRequest;
import com.bss.customer.model.Customer;
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
 *   GET    /tmf-api/customerManagement/v4/customer
 *   POST   /tmf-api/customerManagement/v4/customer
 *   GET    /tmf-api/customerManagement/v4/customer/{id}
 *   PATCH  /tmf-api/customerManagement/v4/customer/{id}     (application/merge-patch+json)
 *   DELETE /tmf-api/customerManagement/v4/customer/{id}
 */
@RestController
@RequestMapping("/tmf-api/customerManagement/v4/customer")
public class CustomerController {

    private final CustomerService service;

    public CustomerController(CustomerService service) {
        this.service = service;
    }

    @GetMapping
    public ResponseEntity<List<Customer>> list(
            @RequestParam(defaultValue = "0") int offset,
            @RequestParam(defaultValue = "20") int limit) {
        var page = service.list(offset, Math.min(limit, 100));
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
