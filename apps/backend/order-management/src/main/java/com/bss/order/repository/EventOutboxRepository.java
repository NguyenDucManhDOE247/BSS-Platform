package com.bss.order.repository;

import com.bss.order.model.EventOutbox;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Query;

import java.util.List;
import java.util.UUID;

public interface EventOutboxRepository extends JpaRepository<EventOutbox, UUID> {

    @Query("""
            SELECT o FROM EventOutbox o
            WHERE o.publishedAt IS NULL
            ORDER BY o.createdAt ASC
            """)
    List<EventOutbox> findUnpublished(org.springframework.data.domain.Pageable pageable);
}
