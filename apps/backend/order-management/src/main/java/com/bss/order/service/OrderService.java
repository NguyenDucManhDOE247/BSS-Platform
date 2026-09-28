package com.bss.order.service;

import com.bss.order.client.CustomerClient;
import com.bss.order.client.OfferingNotOrderableException;
import com.bss.order.client.ProductCatalogClient;
import com.bss.order.security.CurrentCaller;
import org.springframework.http.HttpStatus;
import org.springframework.web.server.ResponseStatusException;
import java.util.LinkedHashMap;
import com.bss.order.dto.CreateOrderRequest;
import com.bss.order.dto.OrderDto;
import com.bss.order.exception.NotFoundException;
import com.bss.order.model.EventOutbox;
import com.bss.order.model.OrderItem;
import com.bss.order.model.ProductOrder;
import com.bss.order.paging.OffsetPageRequest;
import com.bss.order.repository.EventOutboxRepository;
import com.bss.order.repository.ProductOrderRepository;
import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.ObjectMapper;
import org.springframework.data.domain.Page;
import org.springframework.data.domain.Sort;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.time.Instant;
import java.util.Map;
import java.util.UUID;

@Service
@Transactional
public class OrderService {

    private final ProductOrderRepository orders;
    private final EventOutboxRepository outbox;
    private final ObjectMapper json;
    private final ProductCatalogClient catalog;
    private final CustomerClient customers;
    private final CurrentCaller caller;

    public OrderService(ProductOrderRepository orders,
                        EventOutboxRepository outbox,
                        ObjectMapper json,
                        ProductCatalogClient catalog,
                        CustomerClient customers,
                        CurrentCaller caller) {
        this.orders = orders;
        this.outbox = outbox;
        this.json = json;
        this.catalog = catalog;
        this.customers = customers;
        this.caller = caller;
    }

    public OrderDto create(CreateOrderRequest req) {
        var order = new ProductOrder();
        if (caller.authEnabled()) {
            // Giai đoạn 9 (ADR-008 quyết định 3, 4): khách LÀ AI do customer-service trả lời, bằng
            // chính token của khách — body.customerId bị bỏ qua (nếu không, ai cũng đặt hàng dưới tên
            // người khác được). Chỉ khách admin đã duyệt (Active) mới được mua.
            var me = customers.me(caller.bearerToken());
            if (!me.isActive()) {
                throw new CustomerNotActiveException(me.status());
            }
            order.setCustomerId(me.id());
            order.setOwnerSub(caller.subject());
        } else {
            // Auth tắt: hành vi trước GĐ9 (customerId từ body). Xóa nhánh này cùng công tắc.
            if (req.customerId() == null) {
                throw new ResponseStatusException(HttpStatus.UNPROCESSABLE_ENTITY, "customerId: must not be null");
            }
            order.setCustomerId(req.customerId());
        }
        order.setCategory(req.category());
        order.setDescription(req.description());

        for (var item : req.items()) {
            // B-13: price + name are authoritative from product-catalog, never from the caller.
            var offering = catalog.getOffering(item.productOfferingId());
            if (!offering.isOrderable()) {
                throw new OfferingNotOrderableException(item.productOfferingId(), offering.lifecycleStatus());
            }
            var oi = new OrderItem();
            oi.setProductOfferingId(offering.id());
            oi.setProductOfferingName(offering.name());
            oi.setQuantity(item.quantity());
            oi.setUnitPrice(offering.priceAmount());
            order.addItem(oi);
        }
        order.recomputeTotal();

        // Single-step orders auto-complete. Real BSS would orchestrate provisioning.
        order.setState(ProductOrder.State.Completed);
        order.setCompletedAt(Instant.now());

        var saved = orders.save(order);

        // B-11: mint the dedup key *before* building the payload, so it can be embedded in the
        // event body itself. billing-service dedups on this id, not on the EventBridge
        // envelope id (which changes on every PutEvents attempt, including retries of this
        // very row) — see EventOutbox javadoc for the full reasoning.
        UUID eventId = UUID.randomUUID();

        // Outbox row, same TX as the order.
        var payload = new LinkedHashMap<String, Object>();
        payload.put("eventId", eventId.toString());
        payload.put("orderId", saved.getId().toString());
        payload.put("customerId", saved.getCustomerId().toString());
        // Giai đoạn 9 (ADR-008 quyết định 5): billing đóng dấu chủ sở hữu này lên hóa đơn. Chỉ THÊM
        // trường (tương thích ngược) — billing bản cũ phải bỏ qua trường lạ (đã kiểm ở GĐ9 việc 3d).
        if (saved.getOwnerSub() != null) {
            payload.put("customerSub", saved.getOwnerSub());
        }
        payload.put("amount", saved.getTotalAmount().toPlainString());
        payload.put("currency", saved.getCurrency());
        payload.put("completedAt", saved.getCompletedAt().toString());

        outbox.save(EventOutbox.of(
                eventId,
                "ProductOrder", saved.getId(), "OrderCompleted",
                payloadJson(payload)));

        return OrderDto.from(saved);
    }

    /**
     * Giai đoạn 9 (ADR-008 quyết định 5): khách đọc đơn của NGƯỜI KHÁC → 404 (không phải 403, để
     * không xác nhận việc id đó tồn tại). Đơn không có chủ (trước GĐ9 / auth tắt) → chỉ admin thấy.
     */
    @Transactional(readOnly = true)
    public OrderDto get(UUID id) {
        return orders.findById(id)
                .filter(o -> caller.seesEverything() || caller.subject().equals(o.getOwnerSub()))
                .map(OrderDto::from)
                .orElseThrow(() -> new NotFoundException("ProductOrder", id.toString()));
    }

    /**
     * Khách: luôn chỉ đơn của CHÍNH mình ({@code customerId} truyền vào bị bỏ qua). Admin: tất cả,
     * lọc theo khách nếu có {@code customerId}. Auth tắt: như trước GĐ9 ({@code customerId} bắt buộc).
     */
    @Transactional(readOnly = true)
    public Page<OrderDto> list(UUID customerId, int offset, int limit) {
        var pageable = OffsetPageRequest.of(offset, limit, Sort.by("createdAt").descending());
        if (!caller.seesEverything()) {
            return orders.findByOwnerSub(caller.subject(), pageable).map(OrderDto::from);
        }
        if (customerId != null) {
            return orders.findByCustomerId(customerId, pageable).map(OrderDto::from);
        }
        if (!caller.authEnabled()) {
            throw new ResponseStatusException(HttpStatus.BAD_REQUEST, "customerId is required");
        }
        return orders.findAll(pageable).map(OrderDto::from);
    }

    private String payloadJson(Map<String, Object> data) {
        try {
            return json.writeValueAsString(data);
        } catch (JsonProcessingException e) {
            // Map -> JSON serialization with plain types never fails at runtime.
            throw new IllegalStateException("event payload serialization failed", e);
        }
    }
}
