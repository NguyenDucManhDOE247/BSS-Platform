-- expand-contract: bước CONTRACT của email_verified (runbook schema-migration §4). An toàn vì Release B
-- (V4 backfill + code luôn ghi giá trị) đã chạy ở mọi môi trường trước bản này — không còn pod nào ghi
-- NULL. Chạy lại backfill phòng dòng NULL lọt vào giữa V4 và lúc pod A cuối cùng tắt, rồi mới khóa cột.
UPDATE customers SET email_verified = false WHERE email_verified IS NULL;
ALTER TABLE customers ALTER COLUMN email_verified SET DEFAULT false;
ALTER TABLE customers ALTER COLUMN email_verified SET NOT NULL;
