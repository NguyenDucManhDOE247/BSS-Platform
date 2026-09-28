-- Giai đoạn 9 việc 3c (ADR-008 quyết định 5): đóng dấu CHỦ SỞ HỮU (claim `sub` của Keycloak) lên
-- đơn hàng, để "khách chỉ xem đơn của chính mình" kiểm được ngay trong service này, không phải hỏi
-- customer-service ở mỗi request.
-- NULLABLE: đơn cũ (trước GĐ9, của khách "ma" DEMO_CUSTOMER_ID) và đơn tạo khi auth tắt không có
-- chủ sở hữu → chỉ admin thấy. Chỉ thêm cột nullable + index — tương thích ngược (expand).
ALTER TABLE product_order ADD COLUMN owner_sub VARCHAR(64);
CREATE INDEX ix_order_owner_sub ON product_order(owner_sub);
