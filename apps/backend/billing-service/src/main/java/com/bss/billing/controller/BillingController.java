package com.bss.billing.controller;

import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

import java.util.List;
import java.util.Map;

/** Placeholder. Replace with TMF678 BillingAccountManagement endpoints. */
@RestController
@RequestMapping("/tmf-api/billingManagement/v4")
public class BillingController {

    @GetMapping("/billingAccount")
    public List<Map<String, Object>> listAccounts() {
        return List.of(Map.of("status", "scaffold", "todo", "implement TMF678"));
    }
}
