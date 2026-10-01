package com.bss.order;

import com.bss.common.exception.GlobalExceptionHandler;
import com.bss.common.security.CurrentCaller;
import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.context.annotation.Import;
import org.springframework.scheduling.annotation.EnableScheduling;

@SpringBootApplication
@EnableScheduling
// bss-common-java (B-15) nằm ngoài vùng component-scan com.bss.order → đăng ký tường minh. Lỗi riêng của
// đơn hàng (422/503) ở exception/OrderExceptionHandler, chạy cạnh handler chung.
@Import({GlobalExceptionHandler.class, CurrentCaller.class})
public class OrderManagementApplication {
    public static void main(String[] args) {
        SpringApplication.run(OrderManagementApplication.class, args);
    }
}
