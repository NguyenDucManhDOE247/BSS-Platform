-- TMF620 Product Catalog Management — initial schema.
-- Models the three core resources: Category, ProductSpecification, ProductOffering.

CREATE TABLE category (
    id          UUID PRIMARY KEY,
    name        VARCHAR(255) NOT NULL,
    description TEXT,
    parent_id   UUID REFERENCES category(id),
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE product_specification (
    id               UUID PRIMARY KEY,
    name             VARCHAR(255) NOT NULL,
    description      TEXT,
    version          VARCHAR(32)  NOT NULL DEFAULT '1.0',
    lifecycle_status VARCHAR(32)  NOT NULL DEFAULT 'Active',
    created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at       TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE product_offering (
    id                UUID PRIMARY KEY,
    name              VARCHAR(255) NOT NULL,
    description       TEXT,
    category_id       UUID REFERENCES category(id),
    specification_id  UUID REFERENCES product_specification(id),
    lifecycle_status  VARCHAR(32)  NOT NULL DEFAULT 'Active',
    is_bundle         BOOLEAN      NOT NULL DEFAULT false,
    price_amount      NUMERIC(12,2) NOT NULL,
    price_currency    CHAR(3)      NOT NULL DEFAULT 'VND',
    recurring_period  VARCHAR(16)  NOT NULL DEFAULT 'monthly', -- monthly | yearly | one_time
    valid_for_start   TIMESTAMPTZ,
    valid_for_end     TIMESTAMPTZ,
    created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at        TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX ix_offering_category ON product_offering(category_id);
CREATE INDEX ix_offering_status   ON product_offering(lifecycle_status);

-- Seed sample catalog so the UI has something to render.
INSERT INTO category (id, name, description) VALUES
  ('11111111-1111-1111-1111-111111111111', 'Mobile',    'Mobile data + voice plans'),
  ('22222222-2222-2222-2222-222222222222', 'Broadband', 'FTTH and fixed-line internet'),
  ('33333333-3333-3333-3333-333333333333', 'IoT',       'NB-IoT / M2M connectivity');

INSERT INTO product_specification (id, name, description) VALUES
  ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'Mobile Postpaid', 'Postpaid voice + data product'),
  ('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'FTTH 1G',         'Symmetric fiber up to 1 Gbps'),
  ('cccccccc-cccc-cccc-cccc-cccccccccccc', 'IoT SIM',         'Low-power NB-IoT SIM');

INSERT INTO product_offering
    (id, name, description, category_id, specification_id, price_amount, price_currency, recurring_period)
VALUES
  ('d1111111-1111-1111-1111-111111111111', 'Lite 30',
   '5GB data + 100 minutes',
   '11111111-1111-1111-1111-111111111111', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
   99000, 'VND', 'monthly'),
  ('d2222222-2222-2222-2222-222222222222', 'Pro 80',
   '20GB data + unlimited domestic minutes',
   '11111111-1111-1111-1111-111111111111', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
   199000, 'VND', 'monthly'),
  ('d3333333-3333-3333-3333-333333333333', 'Home Fiber 200',
   '200 Mbps symmetric, free wifi router',
   '22222222-2222-2222-2222-222222222222', 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb',
   299000, 'VND', 'monthly'),
  ('d4444444-4444-4444-4444-444444444444', 'IoT Starter',
   '50MB/month NB-IoT SIM',
   '33333333-3333-3333-3333-333333333333', 'cccccccc-cccc-cccc-cccc-cccccccccccc',
   29000, 'VND', 'monthly');
