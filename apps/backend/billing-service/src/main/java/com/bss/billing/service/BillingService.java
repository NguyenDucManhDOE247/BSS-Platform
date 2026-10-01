package com.bss.billing.service;

import com.bss.billing.dto.BillingAccountDto;
import com.bss.billing.dto.CreateAccountRequest;
import com.bss.billing.dto.InvoiceDto;
import com.bss.billing.dto.InvoiceSummaryDto;
import com.bss.common.exception.NotFoundException;
import com.bss.billing.model.BillingAccount;
import com.bss.billing.model.Invoice;
import com.bss.billing.model.InvoiceItem;
import com.bss.common.paging.OffsetPageRequest;
import com.bss.billing.repository.BillingAccountRepository;
import com.bss.billing.repository.InvoiceRepository;
import com.bss.common.security.CurrentCaller;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.data.domain.Page;
import org.springframework.data.domain.Sort;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.math.RoundingMode;
import java.time.LocalDate;
import java.util.UUID;

@Service
@Transactional
public class BillingService {

    /** Vietnamese VAT rate (10%). */
    private static final BigDecimal VAT_RATE = new BigDecimal("0.10");

    private static final Logger log = LoggerFactory.getLogger(BillingService.class);

    private final BillingAccountRepository accounts;
    private final InvoiceRepository invoices;
    private final CurrentCaller caller;

    public BillingService(BillingAccountRepository accounts, InvoiceRepository invoices, CurrentCaller caller) {
        this.accounts = accounts;
        this.invoices = invoices;
        this.caller = caller;
    }

    public BillingAccountDto openAccount(CreateAccountRequest req) {
        var existing = accounts.findByCustomerId(req.customerId());
        if (existing.isPresent()) {
            return BillingAccountDto.from(existing.get());
        }
        var account = new BillingAccount();
        account.setCustomerId(req.customerId());
        account.setName(req.name());
        if (req.paymentMethod() != null) account.setPaymentMethod(req.paymentMethod());
        if (req.currency() != null) account.setCurrency(req.currency());
        return BillingAccountDto.from(accounts.save(account));
    }

    /**
     * Giai đoạn 9 (ADR-008 quyết định 5): khách đọc account của NGƯỜI KHÁC → 404 (không phải 403, để
     * không xác nhận việc id đó tồn tại). Account chưa có chủ → chỉ admin thấy.
     */
    @Transactional(readOnly = true)
    public BillingAccountDto getAccount(UUID id) {
        return accounts.findById(id)
                .filter(a -> caller.seesEverything() || caller.subject().equals(a.getOwnerSub()))
                .map(BillingAccountDto::from)
                .orElseThrow(() -> new NotFoundException("BillingAccount", id.toString()));
    }

    @Transactional(readOnly = true)
    public Page<BillingAccountDto> listAccounts(int offset, int limit) {
        // B-15 fix: OffsetPageRequest, not PageRequest.of(offset/limit,...) — see its javadoc.
        var pageable = OffsetPageRequest.of(offset, limit, Sort.by("createdAt").descending());
        if (!caller.seesEverything()) {
            return accounts.findByOwnerSub(caller.subject(), pageable).map(BillingAccountDto::from);
        }
        return accounts.findAll(pageable).map(BillingAccountDto::from);
    }

    /**
     * Khách: luôn chỉ hóa đơn của CHÍNH mình ({@code customerId} bị bỏ qua). Admin: tất cả, lọc theo
     * khách nếu có {@code customerId}.
     */
    @Transactional(readOnly = true)
    public Page<InvoiceDto> listInvoices(UUID customerId, int offset, int limit) {
        var pageable = OffsetPageRequest.of(offset, limit, Sort.by("invoiceDate").descending());
        if (!caller.seesEverything()) {
            return invoices.findByBillingAccount_OwnerSub(caller.subject(), pageable).map(InvoiceDto::from);
        }
        if (customerId != null) {
            return invoices.findByBillingAccount_CustomerId(customerId, pageable).map(InvoiceDto::from);
        }
        return invoices.findAll(pageable).map(InvoiceDto::from);
    }

    @Transactional(readOnly = true)
    public InvoiceSummaryDto summary() {
        return invoices.summarize();
    }

    /** Giữ cho code/test cũ — tương đương {@link #listInvoices} khi auth tắt. */
    @Transactional(readOnly = true)
    public Page<InvoiceDto> listInvoicesForCustomer(UUID customerId, int offset, int limit) {
        return listInvoices(customerId, offset, limit);
    }

    @Transactional(readOnly = true)
    public InvoiceDto getInvoice(UUID id) {
        return invoices.findById(id)
                .filter(i -> caller.seesEverything()
                        || caller.subject().equals(i.getBillingAccount().getOwnerSub()))
                .map(InvoiceDto::from)
                .orElseThrow(() -> new NotFoundException("Invoice", id.toString()));
    }

    /** Giữ chữ ký cũ (trước GĐ9) — đơn không có chủ sở hữu. */
    public InvoiceDto invoiceFromOrder(UUID customerId, UUID orderId,
                                       String description, BigDecimal amount) {
        return invoiceFromOrder(customerId, null, orderId, description, amount);
    }

    /**
     * Create an invoice from a completed order. Caller (event listener) is responsible
     * for idempotency via processed_event log.
     *
     * @param customerSub Giai đoạn 9: {@code sub} Keycloak của khách (từ event), null nếu đơn tạo lúc
     *                    auth tắt. Gắn cho account nếu account CHƯA có chủ — không bao giờ ghi đè chủ
     *                    cũ bằng 1 giá trị khác (1 khách ↔ 1 tài khoản web, đổi chủ là dấu hiệu bất
     *                    thường → log cảnh báo, giữ nguyên).
     */
    public InvoiceDto invoiceFromOrder(UUID customerId, String customerSub, UUID orderId,
                                       String description, BigDecimal amount) {
        var account = accounts.findByCustomerId(customerId)
                .orElseGet(() -> {
                    // Lazy-open account on first invoice — keeps onboarding flow simple.
                    var fresh = new BillingAccount();
                    fresh.setCustomerId(customerId);
                    fresh.setName("Account for " + customerId);
                    return accounts.save(fresh);
                });
        if (customerSub != null) {
            if (account.getOwnerSub() == null) {
                account.setOwnerSub(customerSub);
            } else if (!account.getOwnerSub().equals(customerSub)) {
                log.warn("Billing account {} đã có chủ khác với customerSub của event — giữ nguyên chủ cũ",
                        account.getId());
            }
        }

        var tax = amount.multiply(VAT_RATE).setScale(2, RoundingMode.HALF_UP);
        var total = amount.add(tax);

        var invoice = new Invoice();
        invoice.setBillingAccount(account);
        invoice.setInvoiceNumber(generateInvoiceNumber());
        invoice.setAmount(total);
        invoice.setTaxAmount(tax);
        invoice.setCurrency(account.getCurrency());
        invoice.setInvoiceDate(LocalDate.now());
        invoice.setDueDate(LocalDate.now().plusDays(15));
        invoice.setState(Invoice.State.Validated);

        var item = new InvoiceItem();
        item.setDescription(description);
        item.setSourceOrderId(orderId);
        item.setQuantity(1);
        item.setUnitPrice(amount);
        item.setAmount(amount);
        invoice.addItem(item);

        return InvoiceDto.from(invoices.save(invoice));
    }

    private String generateInvoiceNumber() {
        // BSS-YYYYMMDD-<8 random hex>. Real-world would use a Postgres sequence
        // or a vendor-specific format. Good enough for portfolio.
        var datePart = LocalDate.now().toString().replace("-", "");
        var randPart = UUID.randomUUID().toString().replace("-", "").substring(0, 8).toUpperCase();
        return "BSS-" + datePart + "-" + randPart;
    }
}
