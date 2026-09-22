package com.bss.customer;

import com.bss.common.exception.GlobalExceptionHandler;
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
// bss-common-java's GlobalExceptionHandler lives under com.bss.common, outside this app's
// default component-scan base package (com.bss.customer) — @Import wires it explicitly, per
// the class's own javadoc.
@Import(GlobalExceptionHandler.class)
public class CustomerServiceApplication {

    public static void main(String[] args) {
        SpringApplication.run(CustomerServiceApplication.class, args);
    }
}
