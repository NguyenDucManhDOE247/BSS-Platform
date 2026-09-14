package com.bss.billing;

import com.bss.billing.dto.CreateAccountRequest;
import com.bss.billing.model.BillingAccount.PaymentMethod;
import com.bss.billing.service.BillingService;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.test.mock.mockito.MockBean;
import org.springframework.boot.testcontainers.service.connection.ServiceConnection;
import org.testcontainers.containers.PostgreSQLContainer;
import org.testcontainers.junit.jupiter.Container;
import org.testcontainers.junit.jupiter.Testcontainers;
import software.amazon.awssdk.services.sqs.SqsClient;

import java.math.BigDecimal;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;

// B-14: disable the @Scheduled SQS poller — a @MockBean SqsClient returns null from
// receiveMessage(), which would otherwise NPE every 5s and drown real test failures in noise.
@SpringBootTest(properties = "bss.sqs.consumer.enabled=false")
@Testcontainers
class BillingServiceIT {

    @Container
    @ServiceConnection
    static PostgreSQLContainer<?> postgres = new PostgreSQLContainer<>("postgres:15-alpine");

    /** SQS isn't wired in tests; AwsConfig still needs a bean to satisfy DI. */
    @MockBean SqsClient sqsClient;

    @Autowired BillingService billing;

    @Test
    void open_account_is_idempotent_per_customer() {
        UUID customerId = UUID.randomUUID();
        var req = new CreateAccountRequest(customerId, "Alice account", PaymentMethod.CreditCard, "VND");

        var first = billing.openAccount(req);
        var second = billing.openAccount(req);

        assertThat(second.id()).isEqualTo(first.id());
    }

    @Test
    void invoice_from_order_applies_vat_and_generates_unique_number() {
        UUID customerId = UUID.randomUUID();
        UUID orderId = UUID.randomUUID();
        var invoice = billing.invoiceFromOrder(customerId, orderId, "Mobile plan", new BigDecimal("100000"));

        assertThat(invoice.invoiceNumber()).startsWith("BSS-");
        assertThat(invoice.taxAmount()).isEqualByComparingTo("10000.00");   // 10% VAT
        assertThat(invoice.amount()).isEqualByComparingTo("110000.00");     // total = base + VAT
        assertThat(invoice.items()).hasSize(1);
        assertThat(invoice.items().get(0).sourceOrderId()).isEqualTo(orderId);
    }
}
