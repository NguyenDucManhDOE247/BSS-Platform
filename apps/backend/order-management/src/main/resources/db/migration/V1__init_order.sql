-- TMF622 Order Management — initial schema.
-- Outbox table supports reliable EventBridge publish (transactional with order write).

CREATE TABLE product_order (
    id                         UUID PRIMARY KEY,
    customer_id                UUID         NOT NULL,
    state                      VARCHAR(32)  NOT NULL DEFAULT 'Acknowledged',
        -- Acknowledged | InProgress | Completed | Cancelled | Failed
    category                   VARCHAR(64),     -- new | upgrade | termination
    description                TEXT,
    total_amount               NUMERIC(12,2) NOT NULL DEFAULT 0,
    currency                   CHAR(3)      NOT NULL DEFAULT 'VND',
    requested_start_date       TIMESTAMPTZ,
    requested_completion_date  TIMESTAMPTZ,
    completed_at               TIMESTAMPTZ,
    created_at                 TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at                 TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE order_item (
    id                     UUID PRIMARY KEY,
    order_id               UUID NOT NULL REFERENCES product_order(id) ON DELETE CASCADE,
    product_offering_id    UUID NOT NULL,        -- foreign key crosses service boundary, no FK constraint
    product_offering_name  VARCHAR(255) NOT NULL,
    quantity               INT          NOT NULL DEFAULT 1,
    unit_price             NUMERIC(12,2) NOT NULL,
    action                 VARCHAR(32)  NOT NULL DEFAULT 'add'  -- add | modify | remove
);

CREATE INDEX ix_order_customer    ON product_order(customer_id);
CREATE INDEX ix_order_state       ON product_order(state);
CREATE INDEX ix_order_item_order  ON order_item(order_id);

-- Transactional outbox — events are written in the same TX as the order;
-- a scheduled publisher drains the table to EventBridge.
CREATE TABLE event_outbox (
    id              UUID PRIMARY KEY,
    aggregate_type  VARCHAR(64)  NOT NULL,
    aggregate_id    UUID         NOT NULL,
    event_type      VARCHAR(64)  NOT NULL,
    payload         JSONB        NOT NULL,
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),
    published_at    TIMESTAMPTZ
);

CREATE INDEX ix_outbox_unpublished
    ON event_outbox(created_at)
    WHERE published_at IS NULL;
