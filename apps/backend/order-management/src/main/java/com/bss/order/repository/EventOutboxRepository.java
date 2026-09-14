package com.bss.order.repository;

import com.bss.order.model.EventOutbox;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;

import java.util.List;
import java.util.UUID;

public interface EventOutboxRepository extends JpaRepository<EventOutbox, UUID> {

    @Query("""
            SELECT o FROM EventOutbox o
            WHERE o.publishedAt IS NULL
            ORDER BY o.createdAt ASC
            """)
    List<EventOutbox> findUnpublished(org.springframework.data.domain.Pageable pageable);

    /**
     * B-12 fix: plain SELECT above lets N replicas read (and publish) the same rows at the
     * same time, because a JPQL/HQL SELECT never takes a row lock. "FOR UPDATE SKIP LOCKED"
     * is Postgres' queue-worker idiom: each replica locks whatever rows it reads, and any
     * other replica's concurrent SELECT ... FOR UPDATE simply skips the rows already locked
     * instead of blocking on them — so N replicas polling at once safely partition the work
     * instead of racing on it.
     * <p>
     * Trade-off we accept for now (documented, not hidden): the caller
     * ({@link com.bss.order.event.OrderEventPublisher#drain()}) keeps this row lock for the
     * whole EventBridge PutEvents network call, because releasing the lock earlier would
     * re-open the double-publish race this query exists to close. That holds one DB
     * connection per replica slightly longer than ideal. If this ever becomes a bottleneck,
     * the fix is a "claim, release, confirm" lease column (claimed_at + claimed_by) or a
     * dedicated scheduler-locking library (ShedLock) — tracked as a follow-up, not needed at
     * this scale (batches of 10, every 2s).
     */
    @Query(value = """
            SELECT * FROM event_outbox
            WHERE published_at IS NULL
            ORDER BY created_at ASC
            LIMIT :limit
            FOR UPDATE SKIP LOCKED
            """, nativeQuery = true)
    List<EventOutbox> lockUnpublishedBatch(@Param("limit") int limit);
}
