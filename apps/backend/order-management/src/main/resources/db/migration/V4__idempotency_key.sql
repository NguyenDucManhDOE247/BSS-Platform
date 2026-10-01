-- B-15 (CLAUDE.md §7 "Idempotency-Key header cho mọi POST mutating"): khách bấm "Xác nhận" 2 lần, hoặc
-- mạng chập chờn làm trình duyệt/thư viện tự gửi lại POST → trước đây thành 2 đơn + 2 hóa đơn (mất tiền
-- thật). Có header Idempotency-Key thì lần gửi thứ 2 trả lại ĐÚNG đơn của lần đầu.
--
-- Khóa = (chủ sở hữu, key): key do client sinh nên chỉ có nghĩa trong phạm vi 1 người dùng — khách A
-- không thể "đụng" key của khách B. PRIMARY KEY cũng là thứ chặn 2 request TRÙNG chạy song song: request
-- thứ 2 chờ request đầu commit rồi vi phạm khóa → rollback cả đơn của nó (→ 409, gửi lại sẽ nhận bản cũ).
-- request_hash: cùng key mà khác nội dung = lỗi của client (422), không phải "trả bản cũ".
--
-- Chỉ THÊM bảng mới — code cũ không biết bảng này vẫn chạy bình thường (expand, tương thích ngược).
-- Chưa có job dọn bản ghi cũ: mỗi đơn có key thêm 1 dòng nhỏ; khi cần thì xóa theo created_at.
CREATE TABLE idempotency_key (
    owner_sub    VARCHAR(64)  NOT NULL,
    idem_key     VARCHAR(255) NOT NULL,
    request_hash VARCHAR(64)  NOT NULL, -- không dùng CHAR: Hibernate validate đòi varchar cho String (như V2)
    order_id     UUID         NOT NULL REFERENCES product_order(id),
    created_at   TIMESTAMPTZ  NOT NULL DEFAULT now(),
    PRIMARY KEY (owner_sub, idem_key)
);
