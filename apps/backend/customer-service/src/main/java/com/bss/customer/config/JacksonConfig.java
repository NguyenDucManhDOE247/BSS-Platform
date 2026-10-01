package com.bss.customer.config;

import com.fasterxml.jackson.databind.Module;
import org.openapitools.jackson.nullable.JsonNullableModule;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;

/**
 * B-15: dạy Jackson kiểu {@code JsonNullable<T>} để PATCH merge-patch (RFC 7396) phân biệt 3 trạng thái
 * của một trường: không gửi (giữ nguyên) · {@code null} (xóa) · có giá trị (đặt). Spring Boot tự gắn mọi
 * bean {@link Module} vào ObjectMapper của Spring MVC.
 */
@Configuration
public class JacksonConfig {

    @Bean
    public Module jsonNullableModule() {
        return new JsonNullableModule();
    }
}
