package com.bss.order.event;

import com.bss.order.model.EventOutbox;
import com.bss.order.repository.EventOutboxRepository;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;
import org.springframework.transaction.annotation.Transactional;
import software.amazon.awssdk.services.eventbridge.EventBridgeClient;
import software.amazon.awssdk.services.eventbridge.model.PutEventsRequest;
import software.amazon.awssdk.services.eventbridge.model.PutEventsRequestEntry;
import software.amazon.awssdk.services.eventbridge.model.PutEventsResultEntry;

import java.time.Instant;
import java.util.List;

/**
 * Outbox drainer: scans unpublished rows and ships them to EventBridge.
 * If PutEvents reports a failed entry, the corresponding row stays unpublished
 * and we retry on the next tick.
 *
 * B-14 fix: {@code @SpringBootTest} boots the full app context including {@code @Scheduled}
 * methods, but tests {@code @MockBean} the {@code EventBridgeClient} — a bare Mockito mock
 * returns {@code null} for {@code putEvents(...)}, so this method NPE'd every 2 seconds
 * during every single test class, drowning real failures in noise. Tests that don't care about
 * the drainer set {@code bss.outbox.publisher.enabled=false} to switch the whole bean off.
 */
@Component
@ConditionalOnProperty(name = "bss.outbox.publisher.enabled", havingValue = "true", matchIfMissing = true)
public class OrderEventPublisher {

    private static final Logger log = LoggerFactory.getLogger(OrderEventPublisher.class);
    private static final int BATCH_SIZE = 10; // EventBridge PutEvents hard limit is 10 entries.

    private final EventBridgeClient client;
    private final EventOutboxRepository outbox;
    private final String eventBusName;

    public OrderEventPublisher(EventBridgeClient client,
                               EventOutboxRepository outbox,
                               @Value("${aws.eventbridge.bus-name}") String eventBusName) {
        this.client = client;
        this.outbox = outbox;
        this.eventBusName = eventBusName;
    }

    @Scheduled(fixedDelay = 2000)
    @Transactional
    public void drain() {
        // B-12: FOR UPDATE SKIP LOCKED so 2+ replicas polling at once each grab a disjoint
        // batch instead of racing to publish (and double-count) the same rows. See the
        // repository method's javadoc for the accepted trade-off (network call stays inside
        // this transaction, holding the row lock for its duration).
        List<EventOutbox> pending = outbox.lockUnpublishedBatch(BATCH_SIZE);
        if (pending.isEmpty()) {
            return;
        }

        var entries = pending.stream()
                .map(e -> PutEventsRequestEntry.builder()
                        .eventBusName(eventBusName)
                        .source("bss.order")
                        .detailType(e.getEventType())
                        .time(Instant.now())
                        .detail(e.getPayload())
                        .build())
                .toList();

        var result = client.putEvents(PutEventsRequest.builder().entries(entries).build());

        List<PutEventsResultEntry> resultEntries = result.entries();
        for (int i = 0; i < resultEntries.size(); i++) {
            PutEventsResultEntry r = resultEntries.get(i);
            if (r.errorCode() == null) {
                pending.get(i).markPublished();
            } else {
                log.warn("EventBridge failed for outbox {}: {} {}",
                        pending.get(i).getId(), r.errorCode(), r.errorMessage());
            }
        }
        outbox.saveAll(pending);
    }
}
