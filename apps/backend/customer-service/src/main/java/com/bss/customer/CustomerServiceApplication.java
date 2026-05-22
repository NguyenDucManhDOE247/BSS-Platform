package com.bss.customer;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;

/**
 * BSS Customer Management Service.
 *
 * Implements a subset of TM Forum TMF629 Customer Management API.
 * See: https://www.tmforum.org/oda/open-apis/directory/customer-management-api-TMF629
 */
@SpringBootApplication
public class CustomerServiceApplication {

    public static void main(String[] args) {
        SpringApplication.run(CustomerServiceApplication.class, args);
    }
}
