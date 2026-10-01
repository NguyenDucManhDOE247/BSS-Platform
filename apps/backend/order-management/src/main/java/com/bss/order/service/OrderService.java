package com.bss.order.service;

import com.bss.common.exception.NotFoundException;
import com.bss.common.id.UuidV7;
import com.bss.common.paging.OffsetPageRequest;
import com.bss.common.security.CurrentCaller;
import com.bss.order.client.CustomerClient;
import com.bss.order.client.OfferingNotOrderableException;
import com.bss.order.client.ProductCatalogClient;
import com.bss.order.dto.CreateOrderRequest;
import com.bss.order.dto.OrderDto;
import com.bss.order.model.EventOutbox;
import com.bss.order.model.IdempotencyKey;
import com.bss.order.model.OrderItem;
import com.bss.order.model.ProductOrder;
import com.bss.order.repository.EventOutboxRepository;
import com.bss.order.repository.IdempotencyKeyRepository;
import com.bss.order.repository.ProductOrderRepository;
import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.ObjectMapper;
import org.springframework.dao.DataIntegrityViolationException;
import org.springframework.data.domain.Page;
import org.springframework.data.domain.Sort;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.time.Instant;
import java.util.HexFormat;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.UUID;
import java.util.regex.Pattern;

@Service
@Transactional
public class OrderService {

    /** 1–255 ký tự ASCII in được (khoảng trắng và ký tự điều khiển không hợp lệ). */
    private static final Pattern IDEMPOTENCY_KEY = Pattern.compile("[\\x21-\\x7E]{1,255}");

    private final ProductOrderRepository orders;
    private final EventOutboxRepository outbox;
    private final IdempotencyKeyRepository idempotencyKeys;
    private final ObjectMapper json;
    private final ProductCatalogClient catalog;
    private final CustomerClient customers;
    private final CurrentCaller caller;

    public OrderService(ProductOrderRepository orders,
                        EventOutboxRepository outbox,
                        IdempotencyKeyRepository idempotencyKeys,
                        ObjectMapper json,
                        ProductCatalogClient catalog,
                        CustomerClient customers,
                        CurrentCaller caller) {
        this.orders = orders;
        this.outbox = outbox;
        this.idempotencyKeys = idempotencyKeys;
        this.json = json;
        this.catalog = catalog;
        this.customers = customers;
        this.caller = caller;
    }

    /** Tạo đơn không có Idempotency-Key (giữ cho code/test gọi trực tiếp). */
    public OrderDto create(CreateOrderRequest req) {
        return create(req, null).order();
    }

    /**
     * B-15: có {@code idempotencyKey} → mỗi (người dùng, key) tạo tối đa MỘT đơn. Gửi lại cùng key + cùng
     * nội dung → trả lại đơn cũ ({@code replayed}), không gọi customer/catalog, không phát event mới.
     * Không có key → hành vi như trước (mỗi request một đơn).
     */
    public CreatedOrder create(CreateOrderRequest req, String idempotencyKey) {
        String requestHash = null;
        if (idempotencyKey != null) {
            if (!IDEMPOTENCY_KEY.matcher(idempotencyKey).matches()) {
                throw IdempotencyKeyException.malformed();
            }
            requestHash = sha256(req);
            var previous = idempotencyKeys.findById(new IdempotencyKey.Key(caller.subject(), idempotencyKey));
            if (previous.isPresent()) {
                if (!previous.get().getRequestHash().equals(requestHash)) {
                    throw IdempotencyKeyException.reusedWithDifferentRequest();
                }
                var original = orders.findById(previous.get().getOrderId())
                        .orElseThrow(() -> new NotFoundException("ProductOrder", previous.get().getOrderId().toString()));
                return new CreatedOrder(OrderDto.from(original), true);
            }
        }

        var saved = placeOrder(req);

        if (idempotencyKey != null) {
            // Đẩy INSERT đơn + outbox xuống trước: lỗi của chúng (nếu có) không được lẫn vào catch bên dưới.
            orders.flush();
            try {
                // saveAndFlush: vi phạm PRIMARY KEY lộ ra NGAY ở đây (không phải lúc commit, ngoài tầm try) →
                // request trùng chạy song song thua cuộc rollback CẢ đơn + outbox của nó.
                idempotencyKeys.saveAndFlush(IdempotencyKey.of(caller.subject(), idempotencyKey, requestHash, saved.getId()));
            } catch (DataIntegrityViolationException raced) {
                throw IdempotencyKeyException.concurrentDuplicate();
            }
        }
        return new CreatedOrder(OrderDto.from(saved), false);
    }

    private ProductOrder placeOrder(CreateOrderRequest req) {
        var order = new ProductOrder();
        // Giai đoạn 9 (ADR-008 quyết định 3, 4): khách LÀ AI do customer-service trả lời, bằng chính
        // token của khách — request không có trường customerId nào để tin (nếu có, ai cũng đặt hàng
        // dưới tên người khác được). Chỉ khách admin đã duyệt (Active) mới được mua.
        var me = customers.me(caller.bearerToken());
        if (!me.isActive()) {
            throw new CustomerNotActiveException(me.status());
        }
        order.setCustomerId(me.id());
        order.setOwnerSub(caller.subject());
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
        // very row) — see EventOutbox javadoc for the full reasoning. B-15: v7 → PK của
        // event_outbox tăng dần theo thời gian (bảng này nhận 1 dòng mỗi đơn, mãi mãi).
        UUID eventId = UuidV7.generate();

        // Outbox row, same TX as the order.
        var payload = new LinkedHashMap<String, Object>();
        payload.put("eventId", eventId.toString());
        payload.put("orderId", saved.getId().toString());
        payload.put("customerId", saved.getCustomerId().toString());
        // Giai đoạn 9 (ADR-008 quyết định 5): billing đóng dấu chủ sở hữu này lên hóa đơn.
        payload.put("customerSub", saved.getOwnerSub());
        payload.put("amount", saved.getTotalAmount().toPlainString());
        payload.put("currency", saved.getCurrency());
        payload.put("completedAt", saved.getCompletedAt().toString());

        outbox.save(EventOutbox.of(
                eventId,
                "ProductOrder", saved.getId(), "OrderCompleted",
                payloadJson(payload)));

        return saved;
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
     * lọc theo khách nếu có {@code customerId}.
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
        return orders.findAll(pageable).map(OrderDto::from);
    }

    /** Dấu vân tay nội dung request (sau khi Jackson đọc — trường lạ như customerId cũ đã bị bỏ). */
    private String sha256(CreateOrderRequest req) {
        try {
            byte[] body = payloadJson(Map.of("request", req)).getBytes(StandardCharsets.UTF_8);
            return HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256").digest(body));
        } catch (NoSuchAlgorithmException e) {
            throw new IllegalStateException("SHA-256 luôn có trong mọi JVM", e);
        }
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
