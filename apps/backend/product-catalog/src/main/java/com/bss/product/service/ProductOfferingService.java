package com.bss.product.service;

import com.bss.product.dto.CreateOfferingRequest;
import com.bss.product.dto.PatchOfferingRequest;
import com.bss.product.dto.ProductOfferingDto;
import com.bss.product.exception.NotFoundException;
import com.bss.product.model.LifecycleStatus;
import com.bss.product.model.ProductOffering;
import com.bss.product.model.ProductOffering.RecurringPeriod;
import com.bss.product.paging.OffsetPageRequest;
import com.bss.product.repository.ProductOfferingRepository;
import org.springframework.data.domain.Page;
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

    /**
     * @param onSaleOnly Giai đoạn 9: true = người gọi là khách (đăng nhập hay chưa) → chỉ gói đang
     *                   bán; false = admin hoặc auth tắt → toàn bộ danh mục như trước.
     */
    @Transactional(readOnly = true)
    public Page<ProductOfferingDto> list(UUID categoryId,
                                         LifecycleStatus status,
                                         int offset,
                                         int limit,
                                         boolean onSaleOnly) {
        // B-15 fix: OffsetPageRequest, not PageRequest.of(offset/limit,...) — see its javadoc.
        var pageable = OffsetPageRequest.of(offset, limit, Sort.by("createdAt").descending());
        return repo.findAll(ProductOfferingRepository.filter(categoryId, status, onSaleOnly), pageable)
                .map(ProductOfferingDto::from);
    }

    /**
     * Gói đã ngừng bán trả 404 với khách: web-portal không hiện được trang mua, và order-management
     * (gọi GET này để lấy giá — B-13) từ chối đặt gói đó.
     */
    @Transactional(readOnly = true)
    public ProductOfferingDto get(UUID id, boolean onSaleOnly) {
        return repo.findById(id)
                .filter(o -> !onSaleOnly || ProductOfferingRepository.ON_SALE.contains(o.getLifecycleStatus()))
                .map(ProductOfferingDto::from)
                .orElseThrow(() -> new NotFoundException("ProductOffering", id.toString()));
    }

    /** Giai đoạn 9: admin sửa giá / mô tả / ngừng bán. Trường null = giữ nguyên (merge-patch). */
    public ProductOfferingDto patch(UUID id, PatchOfferingRequest req) {
        var o = repo.findById(id)
                .orElseThrow(() -> new NotFoundException("ProductOffering", id.toString()));
        if (req.name() != null && !req.name().isBlank()) o.setName(req.name().trim());
        if (req.description() != null) o.setDescription(req.description());
        if (req.priceAmount() != null) o.setPriceAmount(req.priceAmount());
        if (req.lifecycleStatus() != null) o.setLifecycleStatus(req.lifecycleStatus());
        if (req.validForStart() != null) o.setValidForStart(req.validForStart());
        if (req.validForEnd() != null) o.setValidForEnd(req.validForEnd());
        return ProductOfferingDto.from(repo.save(o));
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
