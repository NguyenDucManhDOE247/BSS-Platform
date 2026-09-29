-- Schema migration Release B (docs/runbooks/schema-migration.md §4, dọn nợ Giai đoạn 6).
-- V2 (Release A) thêm cột nullable; từ Release B code luôn ghi giá trị cho dòng MỚI. Câu này lấp các
-- dòng CŨ còn NULL. Bảng nhỏ nên 1 câu là đủ — bảng lớn phải chia batch ngoài Flyway (khóa bảng lâu).
-- Chưa SET NOT NULL ở đây: pod Release A (không biết cột) vẫn có thể đang chạy trong lúc rolling update
-- và insert NULL. Release C (migration riêng, release sau) mới làm contract.
UPDATE customers SET email_verified = false WHERE email_verified IS NULL;
