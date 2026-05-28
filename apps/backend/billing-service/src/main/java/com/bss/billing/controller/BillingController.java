package com.bss.billing.controller;

import com.bss.billing.dto.BillingAccountDto;
import com.bss.billing.dto.CreateAccountRequest;
import com.bss.billing.dto.InvoiceDto;
import com.bss.billing.service.BillingService;
import jakarta.validation.Valid;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.*;

import java.net.URI;
import java.util.List;
import java.util.UUID;

/**
 * TMF678 Customer Bill Management.
 *   GET    /tmf-api/billingManagement/v4/billingAccount
 *   POST   /tmf-api/billingManagement/v4/billingAccount
 *   GET    /tmf-api/billingManagement/v4/billingAccount/{id}
 *   GET    /tmf-api/billingManagement/v4/customerBill?customerId=...
 *   GET    /tmf-api/billingManagement/v4/customerBill/{id}
 */
@RestController
@RequestMapping("/tmf-api/billingManagement/v4")
public class BillingController {

    private final BillingService service;

    public BillingController(BillingService service) {
        this.service = service;
    }

    @GetMapping("/billingAccount")
    public ResponseEntity<List<BillingAccountDto>> listAccounts(
            @RequestParam(defaultValue = "0") int offset,
            @RequestParam(defaultValue = "20") int limit) {
        var page = service.listAccounts(offset, Math.min(limit, 100));
        return ResponseEntity.ok()
                .header("X-Total-Count", String.valueOf(page.getTotalElements()))
                .body(page.getContent());
    }

    @PostMapping("/billingAccount")
    public ResponseEntity<BillingAccountDto> openAccount(@Valid @RequestBody CreateAccountRequest req) {
        var created = service.openAccount(req);
        return ResponseEntity
                .created(URI.create("/tmf-api/billingManagement/v4/billingAccount/" + created.id()))
                .body(created);
    }

    @GetMapping("/billingAccount/{id}")
    public BillingAccountDto getAccount(@PathVariable UUID id) {
        return service.getAccount(id);
    }

    @GetMapping("/customerBill")
    public ResponseEntity<List<InvoiceDto>> listBills(
            @RequestParam UUID customerId,
            @RequestParam(defaultValue = "0") int offset,
            @RequestParam(defaultValue = "20") int limit) {
        var page = service.listInvoicesForCustomer(customerId, offset, Math.min(limit, 100));
        return ResponseEntity.ok()
                .header("X-Total-Count", String.valueOf(page.getTotalElements()))
                .body(page.getContent());
    }

    @GetMapping("/customerBill/{id}")
    public InvoiceDto getBill(@PathVariable UUID id) {
        return service.getInvoice(id);
    }
}
