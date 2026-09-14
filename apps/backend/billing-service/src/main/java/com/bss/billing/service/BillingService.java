package com.bss.billing.service;

import com.bss.billing.dto.BillingAccountDto;
import com.bss.billing.dto.CreateAccountRequest;
import com.bss.billing.dto.InvoiceDto;
import com.bss.billing.exception.NotFoundException;
import com.bss.billing.model.BillingAccount;
import com.bss.billing.model.Invoice;
import com.bss.billing.model.InvoiceItem;
import com.bss.billing.paging.OffsetPageRequest;
import com.bss.billing.repository.BillingAccountRepository;
import com.bss.billing.repository.InvoiceRepository;
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

    private final BillingAccountRepository accounts;
    private final InvoiceRepository invoices;

    public BillingService(BillingAccountRepository accounts, InvoiceRepository invoices) {
        this.accounts = accounts;
        this.invoices = invoices;
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

    @Transactional(readOnly = true)
    public BillingAccountDto getAccount(UUID id) {
        return accounts.findById(id)
                .map(BillingAccountDto::from)
                .orElseThrow(() -> new NotFoundException("BillingAccount", id.toString()));
    }

    @Transactional(readOnly = true)
    public Page<BillingAccountDto> listAccounts(int offset, int limit) {
        // B-15 fix: OffsetPageRequest, not PageRequest.of(offset/limit,...) — see its javadoc.
        var pageable = OffsetPageRequest.of(offset, limit, Sort.by("createdAt").descending());
        return accounts.findAll(pageable).map(BillingAccountDto::from);
    }

    @Transactional(readOnly = true)
    public Page<InvoiceDto> listInvoicesForCustomer(UUID customerId, int offset, int limit) {
        var pageable = OffsetPageRequest.of(offset, limit, Sort.by("invoiceDate").descending());
        return invoices.findByBillingAccount_CustomerId(customerId, pageable)
                .map(InvoiceDto::from);
    }

    @Transactional(readOnly = true)
    public InvoiceDto getInvoice(UUID id) {
        return invoices.findById(id)
                .map(InvoiceDto::from)
                .orElseThrow(() -> new NotFoundException("Invoice", id.toString()));
    }

    /**
     * Create an invoice from a completed order. Caller (event listener) is responsible
     * for idempotency via processed_event log.
     */
    public InvoiceDto invoiceFromOrder(UUID customerId, UUID orderId,
                                       String description, BigDecimal amount) {
        var account = accounts.findByCustomerId(customerId)
                .orElseGet(() -> {
                    // Lazy-open account on first invoice — keeps onboarding flow simple.
                    var fresh = new BillingAccount();
                    fresh.setCustomerId(customerId);
                    fresh.setName("Account for " + customerId);
                    return accounts.save(fresh);
                });

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
