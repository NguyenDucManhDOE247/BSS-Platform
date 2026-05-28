-- TMF678 Customer Bill / Billing Account Management — initial schema.

CREATE TABLE billing_account (
    id              UUID PRIMARY KEY,
    customer_id     UUID         NOT NULL UNIQUE,
    name            VARCHAR(255) NOT NULL,
    state           VARCHAR(32)  NOT NULL DEFAULT 'Active', -- Active | Suspended | Closed
    payment_method  VARCHAR(32)  NOT NULL DEFAULT 'BankTransfer',
    currency        CHAR(3)      NOT NULL DEFAULT 'VND',
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ  NOT NULL DEFAULT now()
);

CREATE TABLE invoice (
    id                  UUID PRIMARY KEY,
    billing_account_id  UUID         NOT NULL REFERENCES billing_account(id),
    invoice_number      VARCHAR(64)  NOT NULL UNIQUE,
    state               VARCHAR(32)  NOT NULL DEFAULT 'New',
        -- New | Validated | Paid | PartiallyPaid | Cancelled
    amount              NUMERIC(12,2) NOT NULL,
    tax_amount          NUMERIC(12,2) NOT NULL DEFAULT 0,
    currency            CHAR(3)      NOT NULL DEFAULT 'VND',
    invoice_date        DATE         NOT NULL,
    due_date            DATE         NOT NULL,
    paid_at             TIMESTAMPTZ,
    created_at          TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at          TIMESTAMPTZ  NOT NULL DEFAULT now()
);

CREATE TABLE invoice_item (
    id               UUID PRIMARY KEY,
    invoice_id       UUID         NOT NULL REFERENCES invoice(id) ON DELETE CASCADE,
    description      VARCHAR(255) NOT NULL,
    source_order_id  UUID,
    quantity         INT          NOT NULL DEFAULT 1,
    unit_price       NUMERIC(12,2) NOT NULL,
    amount           NUMERIC(12,2) NOT NULL
);

-- Idempotency log: prevent double-charging if SQS redelivers the same event.
-- event_id = EventBridge message ID (or computed digest).
CREATE TABLE processed_event (
    event_id      VARCHAR(128) PRIMARY KEY,
    event_type    VARCHAR(64)  NOT NULL,
    processed_at  TIMESTAMPTZ  NOT NULL DEFAULT now()
);

CREATE INDEX ix_invoice_account ON invoice(billing_account_id);
CREATE INDEX ix_invoice_state   ON invoice(state);
CREATE INDEX ix_invoice_due     ON invoice(due_date) WHERE state IN ('New', 'Validated');
