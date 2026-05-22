package com.bss.customer.controller;

import com.bss.customer.model.Customer;
import com.bss.customer.repository.CustomerRepository;
import jakarta.validation.Valid;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.*;
import java.net.URI;
import java.util.List;
import java.util.UUID;

/**
 * Customer REST API.
 *
 * Paths intentionally follow TMF629 conventions:
 *   GET    /tmf-api/customerManagement/v4/customer
 *   POST   /tmf-api/customerManagement/v4/customer
 *   GET    /tmf-api/customerManagement/v4/customer/{id}
 *   PATCH  /tmf-api/customerManagement/v4/customer/{id}
 *   DELETE /tmf-api/customerManagement/v4/customer/{id}
 */
@RestController
@RequestMapping("/tmf-api/customerManagement/v4/customer")
public class CustomerController {

    private final CustomerRepository repository;

    public CustomerController(CustomerRepository repository) {
        this.repository = repository;
    }

    @GetMapping
    public List<Customer> list() {
        return repository.findAll();
    }

    @PostMapping
    public ResponseEntity<Customer> create(@Valid @RequestBody Customer customer) {
        Customer saved = repository.save(customer);
        return ResponseEntity
                .created(URI.create("/tmf-api/customerManagement/v4/customer/" + saved.getId()))
                .body(saved);
    }

    @GetMapping("/{id}")
    public ResponseEntity<Customer> get(@PathVariable UUID id) {
        return repository.findById(id)
                .map(ResponseEntity::ok)
                .orElse(ResponseEntity.notFound().build());
    }

    @DeleteMapping("/{id}")
    public ResponseEntity<Void> delete(@PathVariable UUID id) {
        if (!repository.existsById(id)) {
            return ResponseEntity.notFound().build();
        }
        repository.deleteById(id);
        return ResponseEntity.noContent().build();
    }

    // TODO(learner): implement PATCH (TMF629 uses application/merge-patch+json),
    // plus filtering, pagination, and event notification via TMF688.
}
