-- Same bug/fix as product-catalog's V2 migration (found while bumping Spring Boot 3.2.4 ->
-- 3.2.12 for Trivy CVEs) — Hibernate 6.4.10's stricter schema validator rejects the CHAR(3)
-- V1 declared for both columns, because the JPA entities
-- (BillingAccount.currency, Invoice.currency — both plain `String` with `@Column(length = 3)`)
-- have always meant VARCHAR(3). See product-catalog's V2 for the full explanation.
ALTER TABLE billing_account ALTER COLUMN currency TYPE VARCHAR(3);
ALTER TABLE invoice ALTER COLUMN currency TYPE VARCHAR(3);
