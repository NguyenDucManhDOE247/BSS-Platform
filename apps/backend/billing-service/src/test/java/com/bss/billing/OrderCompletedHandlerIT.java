package com.bss.billing;

import com.bss.billing.listener.OrderCompletedHandler;
import com.bss.billing.repository.InvoiceRepository;
import com.bss.billing.repository.ProcessedEventRepository;
import com.bss.billing.service.BillingService;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ObjectNode;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.test.mock.mockito.MockBean;
import org.springframework.boot.test.mock.mockito.SpyBean;
import org.springframework.boot.testcontainers.service.connection.ServiceConnection;
import org.testcontainers.containers.PostgreSQLContainer;
import org.testcontainers.junit.jupiter.Container;
import org.testcontainers.junit.jupiter.Testcontainers;
import software.amazon.awssdk.services.sqs.SqsClient;

import java.math.BigDecimal;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.doThrow;
import static org.mockito.Mockito.reset;

/**
 * B-10 + B-11 regression tests, written test-first against the bug: before the fix, the first
 * test below (constructed exactly as the "lost invoice forever" scenario from the bug report)
 * failed because {@code processed_event} committed on its own regardless of what happened to
 * the invoice afterwards — see {@link OrderCompletedHandler} javadoc for the full mechanism.
 */
@SpringBootTest(properties = "bss.sqs.consumer.enabled=false") // not exercising the SQS poll loop here
@Testcontainers
class OrderCompletedHandlerIT {

    @Container
    @ServiceConnection
    static PostgreSQLContainer<?> postgres = new PostgreSQLContainer<>("postgres:15-alpine");

    @MockBean SqsClient sqsClient; // AwsConfig still creates a real client bean; not exercised here

    @SpyBean BillingService billing;
    @Autowired OrderCompletedHandler handler;
    @Autowired ProcessedEventRepository processedEvents;
    @Autowired InvoiceRepository invoices;
    @Autowired ObjectMapper json;

    private ObjectNode detailFor(UUID orderId, UUID customerId) {
        return json.createObjectNode()
                .put("orderId", orderId.toString())
                .put("customerId", customerId.toString())
                .put("amount", "100000");
    }

    @Test
    void a_transient_failure_on_first_attempt_does_not_swallow_the_redelivery() {
        UUID orderId = UUID.randomUUID();
        UUID customerId = UUID.randomUUID();
        String eventId = "evt-" + UUID.randomUUID();
        var detail = detailFor(orderId, customerId);

        // Simulate the downstream failure the bug report describes (e.g. a transient DB
        // hiccup while creating the invoice) — NOT calling the real method, exactly like a
        // real failure wouldn't either.
        doThrow(new RuntimeException("simulated downstream failure"))
                .when(billing).invoiceFromOrder(any(UUID.class), any(UUID.class), anyString(), any(BigDecimal.class));

        assertThatThrownBy(() -> handler.handle(eventId, "OrderCompleted", detail))
                .isInstanceOf(RuntimeException.class)
                .hasMessage("simulated downstream failure");

        // B-10: this is the crux of the bug. The pre-fix code committed the dedup row in its
        // own transaction (self-invocation bypassed @Transactional), so it would still be here
        // even though the invoice was never created — dooming every redelivery to be skipped
        // as "already processed". With the fix, the whole handle() call is one transaction:
        // the failure above must roll the dedup insert back too.
        assertThat(processedEvents.findById(eventId)).isEmpty();
        assertThat(invoices.count()).isZero();

        // SQS redelivers the same message after the visibility timeout. Let it succeed now.
        reset(billing);
        handler.handle(eventId, "OrderCompleted", detail);

        assertThat(processedEvents.findById(eventId)).isPresent();
        assertThat(invoices.count()).isEqualTo(1);
    }

    @Test
    void redelivering_the_same_eventId_after_success_is_a_no_op_not_a_second_invoice() {
        UUID orderId = UUID.randomUUID();
        UUID customerId = UUID.randomUUID();
        String eventId = "evt-" + UUID.randomUUID();
        var detail = detailFor(orderId, customerId);

        handler.handle(eventId, "OrderCompleted", detail);
        assertThat(invoices.count()).isEqualTo(1);

        // B-11: SQS's at-least-once delivery means the *same* message can arrive again even
        // after it was fully processed (e.g. the DeleteMessage ack itself is lost). Dedup on
        // eventId must catch this and must NOT create a second invoice.
        assertThatThrownBy(() -> handler.handle(eventId, "OrderCompleted", detail))
                .isInstanceOf(OrderCompletedHandler.DuplicateEventException.class);

        assertThat(invoices.count()).isEqualTo(1);
    }
}
