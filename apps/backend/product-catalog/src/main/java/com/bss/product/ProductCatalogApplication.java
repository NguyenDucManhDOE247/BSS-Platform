package com.bss.product;

import com.bss.common.exception.GlobalExceptionHandler;
import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.context.annotation.Import;

@SpringBootApplication
// bss-common-java (B-15) nằm ngoài vùng component-scan com.bss.product → đăng ký tường minh.
@Import(GlobalExceptionHandler.class)
public class ProductCatalogApplication {
    public static void main(String[] args) {
        SpringApplication.run(ProductCatalogApplication.class, args);
    }
}
