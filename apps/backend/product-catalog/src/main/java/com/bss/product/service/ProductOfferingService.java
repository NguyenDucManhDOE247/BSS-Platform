package com.bss.product.service;

import com.bss.product.dto.CreateOfferingRequest;
import com.bss.product.dto.ProductOfferingDto;
import com.bss.product.exception.NotFoundException;
import com.bss.product.model.LifecycleStatus;
import com.bss.product.model.ProductOffering;
import com.bss.product.model.ProductOffering.RecurringPeriod;
import com.bss.product.repository.ProductOfferingRepository;
import org.springframework.data.domain.Page;
import org.springframework.data.domain.PageRequest;
import org.springframework.data.domain.Sort;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.util.UUID;

@Service
@Transactional
public class ProductOfferingService {

    private final ProductOfferingRepository repo;

    public ProductOfferingService(ProductOfferingRepository repo) {
        this.repo = repo;
    }

    @Transactional(readOnly = true)
    public Page<ProductOfferingDto> list(UUID categoryId,
                                         LifecycleStatus status,
                                         int offset,
                                         int limit) {
        var pageable = PageRequest.of(offset / Math.max(limit, 1), limit,
                Sort.by("createdAt").descending());

        Page<ProductOffering> page;
        if (categoryId != null && status != null) {
            page = repo.findByCategoryIdAndLifecycleStatus(categoryId, status, pageable);
        } else if (categoryId != null) {
            page = repo.findByCategoryId(categoryId, pageable);
        } else if (status != null) {
            page = repo.findByLifecycleStatus(status, pageable);
        } else {
            page = repo.findAll(pageable);
        }
        return page.map(ProductOfferingDto::from);
    }

    @Transactional(readOnly = true)
    public ProductOfferingDto get(UUID id) {
        return repo.findById(id)
                .map(ProductOfferingDto::from)
                .orElseThrow(() -> new NotFoundException("ProductOffering", id.toString()));
    }

    public ProductOfferingDto create(CreateOfferingRequest req) {
        var offering = new ProductOffering();
        offering.setName(req.name());
        offering.setDescription(req.description());
        offering.setCategoryId(req.categoryId());
        offering.setSpecificationId(req.specificationId());
        offering.setPriceAmount(req.priceAmount());
        if (req.priceCurrency() != null) offering.setPriceCurrency(req.priceCurrency());
        if (req.recurringPeriod() != null) offering.setRecurringPeriod(req.recurringPeriod());
        else offering.setRecurringPeriod(RecurringPeriod.monthly);
        if (req.bundle() != null) offering.setBundle(req.bundle());
        offering.setValidForStart(req.validForStart());
        offering.setValidForEnd(req.validForEnd());

        return ProductOfferingDto.from(repo.save(offering));
    }

    public void delete(UUID id) {
        if (!repo.existsById(id)) {
            throw new NotFoundException("ProductOffering", id.toString());
        }
        repo.deleteById(id);
    }
}
