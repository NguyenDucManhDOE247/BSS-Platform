package com.bss.order.controller;

import com.bss.order.event.OrderEventPublisher;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

import java.util.Map;
import java.util.UUID;

/** Placeholder. Replace with TMF622 OrderManagement endpoints. */
@RestController
@RequestMapping("/tmf-api/orderManagement/v4")
public class OrderController {

    private final OrderEventPublisher publisher;

    public OrderController(OrderEventPublisher publisher) {
        this.publisher = publisher;
    }

    @PostMapping("/order")
    public Map<String, Object> createOrder(@RequestBody Map<String, Object> body) {
        var orderId = UUID.randomUUID().toString();
        var customerId = String.valueOf(body.getOrDefault("customerId", "unknown"));
        publisher.publishOrderCompleted(orderId, customerId, String.valueOf(body.get("amount")));
        return Map.of("id", orderId, "state", "completed");
    }
}
