package com.bss.order.controller;

import com.bss.order.dto.CreateOrderRequest;
import com.bss.order.dto.OrderDto;
import com.bss.order.service.OrderService;
import jakarta.validation.Valid;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.*;

import java.net.URI;
import java.util.List;
import java.util.UUID;

/**
 * TMF622 Product Order Management.
 *   POST /tmf-api/orderManagement/v4/productOrder
 *   GET  /tmf-api/orderManagement/v4/productOrder/{id}
 *   GET  /tmf-api/orderManagement/v4/productOrder?customerId=...
 */
@RestController
@RequestMapping("/tmf-api/orderManagement/v4/productOrder")
public class OrderController {

    private final OrderService service;

    public OrderController(OrderService service) {
        this.service = service;
    }

    @PostMapping
    public ResponseEntity<OrderDto> create(@Valid @RequestBody CreateOrderRequest req) {
        var created = service.create(req);
        return ResponseEntity
                .created(URI.create("/tmf-api/orderManagement/v4/productOrder/" + created.id()))
                .body(created);
    }

    @GetMapping("/{id}")
    public OrderDto get(@PathVariable UUID id) {
        return service.get(id);
    }

    /**
     * Giai đoạn 9 (ADR-008): khách → luôn chỉ đơn của CHÍNH mình ({@code customerId} bị bỏ qua);
     * admin → mọi đơn, lọc theo {@code customerId} nếu có. Auth tắt → {@code customerId} bắt buộc
     * như trước GĐ9.
     */
    @GetMapping
    public ResponseEntity<List<OrderDto>> list(
            @RequestParam(required = false) UUID customerId,
            @RequestParam(defaultValue = "0") int offset,
            @RequestParam(defaultValue = "20") int limit) {
        var page = service.list(customerId, offset, Math.min(limit, 100));
        return ResponseEntity.ok()
                .header("X-Total-Count", String.valueOf(page.getTotalElements()))
                .body(page.getContent());
    }
}
