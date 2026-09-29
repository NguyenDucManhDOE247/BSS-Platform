package com.bss.customer.model;

import com.fasterxml.jackson.annotation.JsonIgnore;
import com.fasterxml.jackson.annotation.JsonProperty;
import jakarta.persistence.*;
import jakarta.validation.constraints.Email;
import jakarta.validation.constraints.NotBlank;
import java.time.Instant;
import java.util.UUID;

/**
 * Customer entity. Field naming follows TMF629 where reasonable.
 */
@Entity
@Table(name = "customers")
public class Customer {

    @Id
    @GeneratedValue(strategy = GenerationType.UUID)
    private UUID id;

    @NotBlank
    @Column(nullable = false)
    private String name;

    @Email
    @Column(unique = true, nullable = false)
    private String email;

    @Column(name = "phone_number")
    private String phoneNumber;

    /**
     * Schema migration Release B (runbook schema-migration §4, dọn nợ GĐ6): cột có từ V2 (Release A,
     * nullable, chưa ai đọc/ghi). Từ bản này code LUÔN ghi giá trị (mặc định {@code false}); V4 backfill
     * các dòng cũ. Release C (PR riêng, sau khi B đã chạy ở mọi môi trường) mới {@code SET NOT NULL}.
     * Kiểu {@code Boolean} (không phải {@code boolean}) vì pod Release B có thể đọc dòng chưa backfill.
     */
    @Column(name = "email_verified")
    private Boolean emailVerified = false;

    /**
     * TMF629 status: Initialized, Validated, Active, Suspended, Terminated.
     */
    @Enumerated(EnumType.STRING)
    @Column(nullable = false)
    private CustomerStatus status = CustomerStatus.Initialized;

    /**
     * Giai đoạn 9 (ADR-008 quyết định 3): claim {@code sub} của tài khoản Keycloak đã tự tạo hồ sơ
     * này qua {@code POST /customer/me}. NULL = khách do admin tạo tay (không có tài khoản web).
     * Không đưa ra API (định danh nội bộ, client không cần) — thay bằng {@link #isSelfRegistered()}.
     */
    @JsonIgnore
    @Column(name = "keycloak_user_id", unique = true, updatable = false)
    private String keycloakUserId;

    @Column(name = "created_at", nullable = false, updatable = false)
    private Instant createdAt;

    @Column(name = "updated_at", nullable = false)
    private Instant updatedAt;

    @PrePersist
    void onCreate() {
        this.createdAt = Instant.now();
        this.updatedAt = this.createdAt;
    }

    @PreUpdate
    void onUpdate() {
        this.updatedAt = Instant.now();
    }

    public enum CustomerStatus {
        Initialized, Validated, Active, Suspended, Terminated
    }

    // --- getters / setters omitted for brevity in the README skeleton --- //
    // TODO(learner): generate getters/setters with your IDE, or switch to a
    // Java 21 record + JPA mapping converter for a cleaner model.

    public UUID getId() { return id; }
    public String getName() { return name; }
    public void setName(String name) { this.name = name; }
    public String getEmail() { return email; }
    public void setEmail(String email) { this.email = email; }
    public String getPhoneNumber() { return phoneNumber; }
    public void setPhoneNumber(String phoneNumber) { this.phoneNumber = phoneNumber; }

    /** null (dòng cũ chưa backfill) được coi là chưa xác thực. */
    public boolean isEmailVerified() { return Boolean.TRUE.equals(emailVerified); }
    public void setEmailVerified(boolean emailVerified) { this.emailVerified = emailVerified; }
    public CustomerStatus getStatus() { return status; }
    public void setStatus(CustomerStatus status) { this.status = status; }
    public Instant getCreatedAt() { return createdAt; }
    public Instant getUpdatedAt() { return updatedAt; }
    public String getKeycloakUserId() { return keycloakUserId; }
    public void setKeycloakUserId(String keycloakUserId) { this.keycloakUserId = keycloakUserId; }

    /**
     * Cho admin-console biết khách này có tài khoản web (tự đăng ký) hay do admin tạo tay.
     * READ_ONLY: chỉ xuất ra JSON; client gửi ngược trường này lên sẽ bị bỏ qua thay vì 400.
     */
    @JsonProperty(value = "selfRegistered", access = JsonProperty.Access.READ_ONLY)
    public boolean isSelfRegistered() { return keycloakUserId != null; }
}
