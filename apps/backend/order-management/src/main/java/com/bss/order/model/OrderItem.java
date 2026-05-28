package com.bss.order.model;

import jakarta.persistence.*;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;

import java.math.BigDecimal;
import java.util.UUID;

@Entity
@Table(name = "order_item")
public class OrderItem {

    @Id
    @GeneratedValue(strategy = GenerationType.UUID)
    private UUID id;

    @ManyToOne(fetch = FetchType.LAZY, optional = false)
    @JoinColumn(name = "order_id", nullable = false)
    private ProductOrder order;

    @NotNull
    @Column(name = "product_offering_id", nullable = false)
    private UUID productOfferingId;

    @NotBlank
    @Column(name = "product_offering_name", nullable = false)
    private String productOfferingName;

    @Column(nullable = false)
    private int quantity = 1;

    @NotNull
    @Column(name = "unit_price", nullable = false)
    private BigDecimal unitPrice;

    @Enumerated(EnumType.STRING)
    @Column(nullable = false)
    private Action action = Action.add;

    public enum Action { add, modify, remove }

    public UUID getId() { return id; }
    public ProductOrder getOrder() { return order; }
    public void setOrder(ProductOrder order) { this.order = order; }
    public UUID getProductOfferingId() { return productOfferingId; }
    public void setProductOfferingId(UUID productOfferingId) { this.productOfferingId = productOfferingId; }
    public String getProductOfferingName() { return productOfferingName; }
    public void setProductOfferingName(String name) { this.productOfferingName = name; }
    public int getQuantity() { return quantity; }
    public void setQuantity(int quantity) { this.quantity = quantity; }
    public BigDecimal getUnitPrice() { return unitPrice; }
    public void setUnitPrice(BigDecimal unitPrice) { this.unitPrice = unitPrice; }
    public Action getAction() { return action; }
    public void setAction(Action action) { this.action = action; }
}
