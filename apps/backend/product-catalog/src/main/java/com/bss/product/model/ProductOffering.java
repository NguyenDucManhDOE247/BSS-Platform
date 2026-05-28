package com.bss.product.model;

import jakarta.persistence.*;
import jakarta.validation.constraints.DecimalMin;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;

import java.math.BigDecimal;
import java.time.Instant;
import java.util.UUID;

@Entity
@Table(name = "product_offering")
public class ProductOffering {

    @Id
    @GeneratedValue(strategy = GenerationType.UUID)
    private UUID id;

    @NotBlank
    @Column(nullable = false)
    private String name;

    private String description;

    @Column(name = "category_id")
    private UUID categoryId;

    @Column(name = "specification_id")
    private UUID specificationId;

    @Enumerated(EnumType.STRING)
    @Column(name = "lifecycle_status", nullable = false)
    private LifecycleStatus lifecycleStatus = LifecycleStatus.Active;

    @Column(name = "is_bundle", nullable = false)
    private boolean bundle = false;

    @NotNull
    @DecimalMin("0.0")
    @Column(name = "price_amount", nullable = false)
    private BigDecimal priceAmount;

    @Column(name = "price_currency", nullable = false, length = 3)
    private String priceCurrency = "VND";

    @Enumerated(EnumType.STRING)
    @Column(name = "recurring_period", nullable = false)
    private RecurringPeriod recurringPeriod = RecurringPeriod.monthly;

    @Column(name = "valid_for_start")
    private Instant validForStart;

    @Column(name = "valid_for_end")
    private Instant validForEnd;

    @Column(name = "created_at", nullable = false, updatable = false)
    private Instant createdAt;

    @Column(name = "updated_at", nullable = false)
    private Instant updatedAt;

    @PrePersist
    void onCreate() {
        Instant now = Instant.now();
        this.createdAt = now;
        this.updatedAt = now;
    }

    @PreUpdate
    void onUpdate() {
        this.updatedAt = Instant.now();
    }

    public enum RecurringPeriod { monthly, yearly, one_time }

    public UUID getId() { return id; }
    public String getName() { return name; }
    public void setName(String name) { this.name = name; }
    public String getDescription() { return description; }
    public void setDescription(String description) { this.description = description; }
    public UUID getCategoryId() { return categoryId; }
    public void setCategoryId(UUID categoryId) { this.categoryId = categoryId; }
    public UUID getSpecificationId() { return specificationId; }
    public void setSpecificationId(UUID specificationId) { this.specificationId = specificationId; }
    public LifecycleStatus getLifecycleStatus() { return lifecycleStatus; }
    public void setLifecycleStatus(LifecycleStatus lifecycleStatus) { this.lifecycleStatus = lifecycleStatus; }
    public boolean isBundle() { return bundle; }
    public void setBundle(boolean bundle) { this.bundle = bundle; }
    public BigDecimal getPriceAmount() { return priceAmount; }
    public void setPriceAmount(BigDecimal priceAmount) { this.priceAmount = priceAmount; }
    public String getPriceCurrency() { return priceCurrency; }
    public void setPriceCurrency(String priceCurrency) { this.priceCurrency = priceCurrency; }
    public RecurringPeriod getRecurringPeriod() { return recurringPeriod; }
    public void setRecurringPeriod(RecurringPeriod recurringPeriod) { this.recurringPeriod = recurringPeriod; }
    public Instant getValidForStart() { return validForStart; }
    public void setValidForStart(Instant validForStart) { this.validForStart = validForStart; }
    public Instant getValidForEnd() { return validForEnd; }
    public void setValidForEnd(Instant validForEnd) { this.validForEnd = validForEnd; }
    public Instant getCreatedAt() { return createdAt; }
    public Instant getUpdatedAt() { return updatedAt; }
}
