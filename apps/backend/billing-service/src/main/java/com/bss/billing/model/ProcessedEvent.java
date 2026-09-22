package com.bss.billing.model;

import jakarta.persistence.*;
import org.springframework.data.domain.Persistable;

import java.time.Instant;

/**
 * Idempotency log: dedup SQS deliveries by event ID.
 *
 * <p>Real bug found by CI actually running {@code OrderCompletedHandlerIT} for the first time
 * (Giai đoạn 3): {@code OrderCompletedHandler.handle()} relies on {@code processed.save(...)}
 * throwing a unique-key violation when {@code eventId} already exists, to detect a duplicate
 * delivery. That never happened — a SECOND {@code save()} call for the same {@code eventId}
 * silently succeeded (an UPDATE, not an error) and the handler went on to create a second
 * invoice.
 *
 * <p>The cause: this entity's {@code @Id} is assigned by the caller (not
 * {@code @GeneratedValue}), and Spring Data JPA's default "is this a new row?" heuristic for
 * that case is simply "is the ID field non-null?" — which is true even for a brand-new object
 * that was never saved, since the constructor always sets {@code eventId}. Spring Data JPA
 * responds to "not new" by calling {@code entityManager.merge()} (an UPSERT) instead of
 * {@code persist()} (an INSERT) — so a duplicate {@code eventId} just overwrites the existing
 * row instead of hitting the primary key constraint. Implementing {@link Persistable} replaces
 * that ID-based guess with an explicit answer: every instance built via the constructor below
 * IS new (this class is only ever constructed to attempt an insert, never to represent an
 * update), so {@code save()} always calls {@code persist()}, and a genuine duplicate now hits
 * the primary key and throws {@link org.springframework.dao.DataIntegrityViolationException} as
 * {@link com.bss.billing.listener.OrderCompletedHandler} already expected it to.
 */
@Entity
@Table(name = "processed_event")
public class ProcessedEvent implements Persistable<String> {

    @Id
    @Column(name = "event_id", length = 128)
    private String eventId;

    @Column(name = "event_type", nullable = false, length = 64)
    private String eventType;

    @Column(name = "processed_at", nullable = false)
    private Instant processedAt = Instant.now();

    @Transient
    private boolean isNew = true;

    protected ProcessedEvent() {}

    public ProcessedEvent(String eventId, String eventType) {
        this.eventId = eventId;
        this.eventType = eventType;
        this.processedAt = Instant.now();
    }

    @Override
    public String getId() { return eventId; }

    @Override
    public boolean isNew() { return isNew; }

    // Only an entity actually loaded from (or just written to) the DB is "not new" going
    // forward — a plain `new ProcessedEvent(...)` stays `isNew() == true` until then.
    @PostLoad
    @PostPersist
    void markNotNew() { this.isNew = false; }

    public String getEventId() { return eventId; }
    public String getEventType() { return eventType; }
    public Instant getProcessedAt() { return processedAt; }
}
