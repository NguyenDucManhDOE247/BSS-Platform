-- Giai đoạn 9 việc 3 (ADR-008 quyết định 3): gắn Customer với tài khoản Keycloak (claim `sub`).
-- NULLABLE: khách do admin tạo tay (khách tại quầy) không có tài khoản web. Postgres cho phép
-- nhiều NULL trong 1 unique index, nên ràng buộc "1 tài khoản web ↔ tối đa 1 khách" vẫn đúng.
-- Chỉ thêm cột nullable + index — tương thích ngược (expand), code cũ không biết cột này vẫn chạy.
ALTER TABLE customers ADD COLUMN keycloak_user_id VARCHAR(64);
CREATE UNIQUE INDEX ux_customers_keycloak_user_id ON customers (keycloak_user_id);
