package com.bss.product.controller;

import com.bss.product.exception.NotFoundException;
import com.bss.product.model.Category;
import com.bss.product.repository.CategoryRepository;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

import java.util.List;
import java.util.UUID;

/** TMF620 Category resource — read-only for now. */
@RestController
@RequestMapping("/tmf-api/productCatalog/v4/category")
public class CategoryController {

    private final CategoryRepository repo;

    public CategoryController(CategoryRepository repo) {
        this.repo = repo;
    }

    @GetMapping
    public List<Category> list() {
        return repo.findAll();
    }

    @GetMapping("/{id}")
    public Category get(@PathVariable UUID id) {
        return repo.findById(id)
                .orElseThrow(() -> new NotFoundException("Category", id.toString()));
    }
}
