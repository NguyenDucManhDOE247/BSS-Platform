package com.bss.customer.service;

import com.bss.customer.dto.CreateCustomerRequest;
import com.bss.customer.dto.MyProfileRequest;
import com.bss.customer.dto.PatchCustomerRequest;
import com.bss.common.exception.NotFoundException;
import com.bss.customer.model.Customer;
import com.bss.customer.model.Customer.CustomerStatus;
import com.bss.customer.paging.OffsetPageRequest;
import com.bss.customer.repository.CustomerRepository;
import org.springframework.data.domain.Page;
import org.springframework.data.domain.Sort;
import org.springframework.http.HttpStatus;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;
import org.springframework.web.server.ResponseStatusException;

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
    public Customer createMine(String subject, String email, MyProfileRequest req) {
        if (email == null || email.isBlank()) {
            throw new ResponseStatusException(HttpStatus.UNPROCESSABLE_ENTITY,
                    "Tài khoản đăng nhập không có email — bổ sung email ở trang tài khoản Keycloak trước");
        }
        if (req.name() == null || req.name().isBlank()) {
            throw new ResponseStatusException(HttpStatus.UNPROCESSABLE_ENTITY, "name: must not be blank");
        }
        if (repo.findByKeycloakUserId(subject).isPresent()) {
            throw new ResponseStatusException(HttpStatus.CONFLICT, "Tài khoản này đã có hồ sơ khách hàng");
        }
        var customer = new Customer();
        customer.setKeycloakUserId(subject);
        customer.setName(req.name().trim());
        customer.setEmail(email);
        customer.setPhoneNumber(req.phoneNumber());
        // Email đã thuộc 1 khách khác (vd. khách tại quầy do admin tạo) → unique constraint →
        // GlobalExceptionHandler trả 409. CỐ Ý không tự "nhận" hồ sơ đó: Keycloak local chưa xác
        // thực email (verifyEmail=false), ai cũng có thể đăng ký bằng email của người khác.
        return repo.save(customer);
    }

    public Customer patchMine(String subject, MyProfileRequest req) {
        var mine = getMine(subject);
        if (req.name() != null && !req.name().isBlank()) mine.setName(req.name().trim());
        if (req.phoneNumber() != null) mine.setPhoneNumber(req.phoneNumber());
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
        customer.setPhoneNumber(req.phoneNumber());
        // status is intentionally NOT settable from the request — see CreateCustomerRequest.
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
