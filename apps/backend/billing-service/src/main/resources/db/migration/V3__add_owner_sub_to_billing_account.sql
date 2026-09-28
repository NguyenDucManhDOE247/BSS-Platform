-- Giai đoạn 9 việc 3d (ADR-008 quyết định 5): chủ sở hữu (claim `sub` Keycloak) của billing account,
-- lấy từ trường `customerSub` trong event OrderCompleted (việc 3c). Đóng dấu ở cấp ACCOUNT (không
-- phải từng hóa đơn): mỗi khách có đúng 1 account (customer_id unique) và hóa đơn thuộc account →
-- "khách chỉ xem hóa đơn của mình" = lọc theo owner_sub của account, không lặp dữ liệu lên mỗi hóa đơn.
-- NULLABLE: account tạo từ đơn lúc auth tắt / trước GĐ9 → chỉ admin thấy, cho tới khi có 1 event
-- mang customerSub của đúng khách đó (gắn chủ bù). Chỉ thêm cột + index — tương thích ngược.
ALTER TABLE billing_account ADD COLUMN owner_sub VARCHAR(64);
CREATE INDEX ix_billing_account_owner_sub ON billing_account(owner_sub);
