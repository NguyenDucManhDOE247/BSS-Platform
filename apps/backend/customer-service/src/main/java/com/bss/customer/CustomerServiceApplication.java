package com.bss.customer;

import com.bss.common.exception.GlobalExceptionHandler;
import com.bss.common.security.CurrentCaller;
import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.context.annotation.Import;

/**
 * BSS Customer Management Service.
 *
 * Implements a subset of TM Forum TMF629 Customer Management API.
 * See: https://www.tmforum.org/oda/open-apis/directory/customer-management-api-TMF629
 */
@SpringBootApplication
// bss-common-java lives under com.bss.common, outside this app's default component-scan base
// package (com.bss.customer) — @Import wires its beans explicitly (B-15).
@Import({GlobalExceptionHandler.class, CurrentCaller.class})
public class CustomerServiceApplication {

    public static void main(String[] args) {
        SpringApplication.run(CustomerServiceApplication.class, args);
    }
}
