package com.bss.billing.model;

import jakarta.persistence.*;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;

import java.time.Instant;
import java.util.UUID;

@Entity
@Table(name = "billing_account")
public class BillingAccount {

    @Id
    @GeneratedValue(strategy = GenerationType.UUID)
    private UUID id;

    @NotNull
    @Column(name = "customer_id", nullable = false, unique = true)
    private UUID customerId;

    @NotBlank
    @Column(nullable = false)
    private String name;

    /**
     * Giai đoạn 9 (ADR-008 quyết định 5): {@code sub} Keycloak của khách sở hữu account (và mọi hóa
     * đơn trong đó). NULL = chưa biết chủ (account từ đơn lúc auth tắt / trước GĐ9) → chỉ admin thấy.
     */
    @Column(name = "owner_sub", length = 64)
    private String ownerSub;

    @Enumerated(EnumType.STRING)
    @Column(nullable = false)
    private State state = State.Active;

    @Enumerated(EnumType.STRING)
    @Column(name = "payment_method", nullable = false)
    private PaymentMethod paymentMethod = PaymentMethod.BankTransfer;

    @Column(nullable = false, length = 3)
    private String currency = "VND";

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

    public enum State { Active, Suspended, Closed }

    public enum PaymentMethod { BankTransfer, CreditCard, EWallet, Cash }

    public UUID getId() { return id; }
    public UUID getCustomerId() { return customerId; }
    public void setCustomerId(UUID customerId) { this.customerId = customerId; }
    public String getName() { return name; }
    public void setName(String name) { this.name = name; }
    public String getOwnerSub() { return ownerSub; }
    public void setOwnerSub(String ownerSub) { this.ownerSub = ownerSub; }
    public State getState() { return state; }
    public void setState(State state) { this.state = state; }
    public PaymentMethod getPaymentMethod() { return paymentMethod; }
    public void setPaymentMethod(PaymentMethod paymentMethod) { this.paymentMethod = paymentMethod; }
    public String getCurrency() { return currency; }
    public void setCurrency(String currency) { this.currency = currency; }
    public Instant getCreatedAt() { return createdAt; }
    public Instant getUpdatedAt() { return updatedAt; }
}
