-- TMF629 Customer Management — initial schema.
CREATE TABLE customers (
    id           UUID PRIMARY KEY,
    name         VARCHAR(255) NOT NULL,
    email        VARCHAR(255) NOT NULL UNIQUE,
    phone_number VARCHAR(64),
    status       VARCHAR(32)  NOT NULL DEFAULT 'Initialized',
    created_at   TIMESTAMPTZ  NOT NULL,
    updated_at   TIMESTAMPTZ  NOT NULL
);

CREATE INDEX ix_customers_status ON customers(status);
