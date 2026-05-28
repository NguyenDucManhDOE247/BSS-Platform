package com.bss.customer.service;

import com.bss.customer.dto.PatchCustomerRequest;
import com.bss.customer.exception.NotFoundException;
import com.bss.customer.model.Customer;
import com.bss.customer.repository.CustomerRepository;
import org.springframework.data.domain.Page;
import org.springframework.data.domain.PageRequest;
import org.springframework.data.domain.Sort;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.util.UUID;

@Service
@Transactional
public class CustomerService {

    private final CustomerRepository repo;

    public CustomerService(CustomerRepository repo) {
        this.repo = repo;
    }

    @Transactional(readOnly = true)
    public Page<Customer> list(int offset, int limit) {
        var pageable = PageRequest.of(offset / Math.max(limit, 1), limit,
                Sort.by("createdAt").descending());
        return repo.findAll(pageable);
    }

    @Transactional(readOnly = true)
    public Customer get(UUID id) {
        return repo.findById(id)
                .orElseThrow(() -> new NotFoundException("Customer", id.toString()));
    }

    public Customer create(Customer customer) {
        return repo.save(customer);
    }

    public Customer patch(UUID id, PatchCustomerRequest req) {
        var existing = get(id);
        if (req.name() != null) existing.setName(req.name());
        if (req.email() != null) existing.setEmail(req.email());
        if (req.phoneNumber() != null) existing.setPhoneNumber(req.phoneNumber());
        if (req.status() != null) existing.setStatus(req.status());
        return repo.save(existing);
    }

    public void delete(UUID id) {
        if (!repo.existsById(id)) {
            throw new NotFoundException("Customer", id.toString());
        }
        repo.deleteById(id);
    }
}
