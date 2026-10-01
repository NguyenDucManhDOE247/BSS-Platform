package com.bss.customer.service;

import com.bss.common.exception.NotFoundException;
import com.bss.common.paging.OffsetPageRequest;
import com.bss.customer.dto.CreateCustomerRequest;
import com.bss.customer.dto.MyProfileRequest;
import com.bss.customer.dto.PatchCustomerRequest;
import com.bss.customer.model.Customer;
import com.bss.customer.model.Customer.CustomerStatus;
import com.bss.customer.repository.CustomerRepository;
import org.openapitools.jackson.nullable.JsonNullable;
import org.springframework.data.domain.Page;
import org.springframework.data.domain.Sort;
import org.springframework.http.HttpStatus;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;
import org.springframework.web.server.ResponseStatusException;

import java.util.Optional;
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
        return list(offset, limit, null, null);
    }

    /** Giai đoạn 9: lọc theo trạng thái (vd. chờ duyệt) + tìm theo tên/email — cho admin-console. */
    @Transactional(readOnly = true)
    public Page<Customer> list(int offset, int limit, CustomerStatus status, String q) {
        // B-15 fix: see OffsetPageRequest javadoc — PageRequest.of(offset/limit, ...) truncated
        // non-multiple offsets to the wrong page.
        var pageable = OffsetPageRequest.of(offset, limit, Sort.by("createdAt").descending());
        return repo.findAll(CustomerRepository.filter(status, q), pageable);
    }

    // ---------- Giai đoạn 9 (ADR-008): khách tự quản lý hồ sơ của CHÍNH mình ----------

    @Transactional(readOnly = true)
    public Customer getMine(String subject) {
        return repo.findByKeycloakUserId(subject)
                .orElseThrow(() -> new NotFoundException("Customer profile of current user", subject));
    }

    /**
     * Khách vừa đăng ký Keycloak tự tạo hồ sơ. Email lấy từ token (không từ body); trạng thái luôn
     * {@code Initialized} — admin duyệt sang {@code Active} mới được đặt hàng (ADR-008 quyết định 3).
     */
    public Customer createMine(String subject, String email, boolean emailVerified, MyProfileRequest req) {
        if (email == null || email.isBlank()) {
            throw new ResponseStatusException(HttpStatus.UNPROCESSABLE_ENTITY,
                    "Tài khoản đăng nhập không có email — bổ sung email ở trang tài khoản Keycloak trước");
        }
        String name = req.name() == null ? null : req.name().orElse(null);
        if (name == null || name.isBlank()) {
            throw new ResponseStatusException(HttpStatus.UNPROCESSABLE_ENTITY, "name: must not be blank");
        }
        if (repo.findByKeycloakUserId(subject).isPresent()) {
            throw new ResponseStatusException(HttpStatus.CONFLICT, "Tài khoản này đã có hồ sơ khách hàng");
        }
        var customer = new Customer();
        customer.setKeycloakUserId(subject);
        customer.setName(name.trim());
        customer.setEmail(email);
        customer.setEmailVerified(emailVerified); // email đến từ token → tin trạng thái xác thực của Keycloak
        customer.setPhoneNumber(req.phoneNumber() == null ? null : req.phoneNumber().orElse(null));
        // Email đã thuộc 1 khách khác (vd. khách tại quầy do admin tạo) → unique constraint →
        // GlobalExceptionHandler trả 409. CỐ Ý không tự "nhận" hồ sơ đó: Keycloak local chưa xác
        // thực email (verifyEmail=false), ai cũng có thể đăng ký bằng email của người khác.
        return repo.save(customer);
    }

    /** merge-patch (RFC 7396, B-15): không gửi = giữ; {@code phoneNumber: null} = xóa; {@code name} bắt buộc. */
    public Customer patchMine(String subject, MyProfileRequest req) {
        var mine = getMine(subject);
        present(req.name()).ifPresent(n -> mine.setName(requiredText(n, "name")));
        present(req.phoneNumber()).ifPresent(p -> mine.setPhoneNumber(p.orElse(null)));
        return repo.save(mine);
    }

    @Transactional(readOnly = true)
    public Customer get(UUID id) {
        return repo.findById(id)
                .orElseThrow(() -> new NotFoundException("Customer", id.toString()));
    }

    public Customer create(CreateCustomerRequest req) {
        var customer = new Customer();
        customer.setName(req.name());
        customer.setEmail(req.email());
        customer.setEmailVerified(false); // admin gõ tay → chưa ai xác thực email này
        customer.setPhoneNumber(req.phoneNumber());
        // status is intentionally NOT settable from the request — see CreateCustomerRequest.
        return repo.save(customer);
    }

    /** merge-patch (RFC 7396, B-15): không gửi = giữ; {@code phoneNumber: null} = xóa; trường bắt buộc + null = 422. */
    public Customer patch(UUID id, PatchCustomerRequest req) {
        var existing = get(id);
        present(req.name()).ifPresent(n -> existing.setName(requiredText(n, "name")));
        present(req.email()).ifPresent(e -> {
            String email = requiredText(e, "email");
            if (!email.equalsIgnoreCase(existing.getEmail())) {
                existing.setEmail(email);
                existing.setEmailVerified(false); // email mới chưa được xác thực
            }
        });
        present(req.phoneNumber()).ifPresent(p -> existing.setPhoneNumber(p.orElse(null)));
        present(req.status()).ifPresent(s -> existing.setStatus(s.orElseThrow(() -> cannotRemove("status"))));
        return repo.save(existing);
    }

    // ---------- merge-patch (RFC 7396) — B-15 ----------

    /**
     * Trường CÓ trong body → {@code Optional.of(giá trị-có-thể-null)}; không gửi → {@code Optional.empty()}.
     * {@code field == null} khi cả body thiếu trường này mà Jackson không gọi tới (vd. test dựng record tay).
     */
    private static <T> Optional<Optional<T>> present(JsonNullable<T> field) {
        return field != null && field.isPresent() ? Optional.of(Optional.ofNullable(field.get())) : Optional.empty();
    }

    private static String requiredText(Optional<String> value, String field) {
        String v = value.orElseThrow(() -> cannotRemove(field));
        if (v.isBlank()) {
            throw new ResponseStatusException(HttpStatus.UNPROCESSABLE_ENTITY, field + ": must not be blank");
        }
        return v.trim();
    }

    private static ResponseStatusException cannotRemove(String field) {
        return new ResponseStatusException(HttpStatus.UNPROCESSABLE_ENTITY,
                field + ": bắt buộc — merge-patch gửi null nghĩa là xóa, trường này không xóa được");
    }

    public void delete(UUID id) {
        if (!repo.existsById(id)) {
            throw new NotFoundException("Customer", id.toString());
        }
        repo.deleteById(id);
    }
}
