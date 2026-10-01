package com.bss.customer.dto;

import com.bss.customer.model.Customer.CustomerStatus;
import jakarta.validation.constraints.Email;
import org.openapitools.jackson.nullable.JsonNullable;

/**
 * Admin sửa khách — {@code application/merge-patch+json} đúng RFC 7396 (B-15). Mỗi trường có 3 trạng thái:
 * <ul>
 *   <li>không gửi → giữ nguyên ({@code JsonNullable.undefined()}, {@code isPresent() == false});</li>
 *   <li>gửi {@code null} → XÓA trường — chỉ {@code phoneNumber} xóa được; {@code name/email/status} là bắt
 *       buộc nên {@code null} → 422;</li>
 *   <li>gửi giá trị → đặt giá trị đó.</li>
 * </ul>
 * Trước B-15 là record {@code String}: không phân biệt được "không gửi" với {@code null} → không có cách
 * nào xóa số điện thoại. {@code Optional<T>} cũng không được (Jackson trả {@code Optional.empty} cho cả hai).
 */
public record PatchCustomerRequest(
        JsonNullable<String> name,
        JsonNullable<@Email String> email,
        JsonNullable<String> phoneNumber,
        JsonNullable<CustomerStatus> status
) {}
