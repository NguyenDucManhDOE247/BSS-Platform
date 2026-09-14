package com.bss.billing.listener;

import com.bss.billing.model.ProcessedEvent;
import com.bss.billing.repository.ProcessedEventRepository;
import com.bss.billing.service.BillingService;
import com.fasterxml.jackson.databind.JsonNode;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.dao.DataIntegrityViolationException;
import org.springframework.stereotype.Component;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.util.UUID;

/**
 * B-10 fix: this used to be a private/package method on {@link OrderEventListener} itself,
 * called as {@code handle(msg)} from within the same class. Spring's {@code @Transactional}
 * works by wrapping the *bean* in a proxy that starts/commits the transaction around calls
 * coming from OTHER beans — a call from a method in the same class ("self-invocation") never
 * goes through that proxy, so the annotation was silently a no-op.
 *
 * <p>Concretely, that meant {@code saveDedupKey(...)} committed on its own (a plain repository
 * call, own transaction) the instant it ran, regardless of what happened afterwards. If
 * {@code invoiceFromOrder(...)} then threw, the message stayed on the queue (correct — SQS
 * will redeliver it) but the redelivery's dedup check saw the eventId already marked
 * processed and skipped straight to ACK — an invoice that should have been created on retry
 * never was, silently and permanently.
 *
 * <p>The fix is exactly what this class is: a *separate* Spring bean, called from
 * {@link OrderEventListener} (a different bean) so the {@code @Transactional} proxy is
 * actually in the call path. Now dedup-insert and invoice-creation commit or roll back
 * together — a failed {@code invoiceFromOrder} call rolls the dedup insert back too, so
 * redelivery correctly retries the whole thing instead of skipping it as "already processed".
 */
@Component
public class OrderCompletedHandler {

    private static final Logger log = LoggerFactory.getLogger(OrderCompletedHandler.class);

    private final ProcessedEventRepository processed;
    private final BillingService billing;

    public OrderCompletedHandler(ProcessedEventRepository processed, BillingService billing) {
        this.processed = processed;
        this.billing = billing;
    }

    /**
     * @throws DuplicateEventException if this eventId was already processed — caller should
     *                                  log it and ACK (not retry).
     */
    @Transactional
    public void handle(String eventId, String eventType, JsonNode detail) {
        try {
            processed.save(new ProcessedEvent(eventId, eventType));
            processed.flush(); // force the unique-key violation now, inside this same TX
        } catch (DataIntegrityViolationException dup) {
            throw new DuplicateEventException(eventId);
        }

        UUID orderId = UUID.fromString(detail.get("orderId").asText());
        UUID customerId = UUID.fromString(detail.get("customerId").asText());
        BigDecimal amount = new BigDecimal(detail.get("amount").asText());
        String description = "Order " + orderId;

        // If invoiceFromOrder throws, this whole method rolls back — including the
        // processed_event insert above — so a redelivery of the same message tries again
        // instead of being skipped as a false duplicate. This is the crux of the B-10 fix.
        var invoice = billing.invoiceFromOrder(customerId, orderId, description, amount);
        log.info("Issued invoice {} for order {}", invoice.invoiceNumber(), orderId);
    }

    public static class DuplicateEventException extends RuntimeException {
        public DuplicateEventException(String eventId) {
            super(eventId);
        }
    }
}
