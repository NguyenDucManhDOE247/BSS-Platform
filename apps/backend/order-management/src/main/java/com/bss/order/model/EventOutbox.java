package com.bss.order.model;

import jakarta.persistence.*;
import org.hibernate.annotations.JdbcTypeCode;
import org.hibernate.type.SqlTypes;

import java.time.Instant;
import java.util.UUID;

/**
 * Transactional outbox row. Written in the same TX as the aggregate change;
 * a scheduled publisher drains rows to EventBridge and sets published_at.
 *
 * Why outbox: guarantees "if the order commits, the event will eventually publish",
 * even if EventBridge is down at the moment of commit. Avoids the dual-write problem.
 *
 * Payload is stored as a JSON string in a jsonb column. Hibernate 6's @JdbcTypeCode(JSON)
 * handles the bind without needing hypersistence-utils.
 */
@Entity
@Table(name = "event_outbox")
public class EventOutbox {

    @Id
    @GeneratedValue(strategy = GenerationType.UUID)
    private UUID id;

    @Column(name = "aggregate_type", nullable = false, length = 64)
    private String aggregateType;

    @Column(name = "aggregate_id", nullable = false)
    private UUID aggregateId;

    @Column(name = "event_type", nullable = false, length = 64)
    private String eventType;

    @JdbcTypeCode(SqlTypes.JSON)
    @Column(nullable = false, columnDefinition = "jsonb")
    private String payload;

    @Column(name = "created_at", nullable = false, updatable = false)
    private Instant createdAt;

    @Column(name = "published_at")
    private Instant publishedAt;

    @PrePersist
    void onCreate() {
        this.createdAt = Instant.now();
    }

    public static EventOutbox of(String aggregateType, UUID aggregateId,
                                 String eventType, String payloadJson) {
        var o = new EventOutbox();
        o.aggregateType = aggregateType;
        o.aggregateId = aggregateId;
        o.eventType = eventType;
        o.payload = payloadJson;
        return o;
    }

    public UUID getId() { return id; }
    public String getAggregateType() { return aggregateType; }
    public UUID getAggregateId() { return aggregateId; }
    public String getEventType() { return eventType; }
    public String getPayload() { return payload; }
    public Instant getCreatedAt() { return createdAt; }
    public Instant getPublishedAt() { return publishedAt; }
    public void markPublished() { this.publishedAt = Instant.now(); }
}
