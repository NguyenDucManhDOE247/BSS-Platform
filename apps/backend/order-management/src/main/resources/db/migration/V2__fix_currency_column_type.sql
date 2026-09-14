-- Same bug/fix as product-catalog's V2 migration (found while bumping Spring Boot 3.2.4 ->
-- 3.2.12 for Trivy CVEs) — Hibernate 6.4.10's stricter schema validator rejects the CHAR(3)
-- V1 declared here because the JPA entity (ProductOrder.currency, plain `String` with
-- `@Column(length = 3)`) has always meant VARCHAR(3). See product-catalog's V2 for the full
-- explanation.
ALTER TABLE product_order ALTER COLUMN currency TYPE VARCHAR(3);
