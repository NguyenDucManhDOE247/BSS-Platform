package com.bss.billing;

import com.bss.common.exception.GlobalExceptionHandler;
import com.bss.common.security.CurrentCaller;
import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.context.annotation.Import;
import org.springframework.scheduling.annotation.EnableScheduling;

@SpringBootApplication
@EnableScheduling
// bss-common-java (B-15) nằm ngoài vùng component-scan com.bss.billing → đăng ký tường minh.
@Import({GlobalExceptionHandler.class, CurrentCaller.class})
public class BillingServiceApplication {
    public static void main(String[] args) {
        SpringApplication.run(BillingServiceApplication.class, args);
    }
}
