# Runbook — Migration schema tương thích ngược (expand → migrate → contract)

Giai đoạn 6, việc 7 (course 11.6). Liên quan: [ADR-005](../adr/ADR-005-nguon-su-that-phien-ban-cd.md) (rollback),
[cd-promotion.md](cd-promotion.md), checker: `scripts/check-migrations.sh` (chạy trong CI của mọi PR).

## 1. Vấn đề: hai phiên bản code cùng chạy trên MỘT database

Mỗi service tự chạy Flyway **lúc khởi động** (`spring.flyway.enabled: true`, `ddl-auto: validate`). Khi CD
rolling-update một service (`maxSurge: 1`, `maxUnavailable: 0`):

```
t0   pod v1 ─────────────────────────────────────────────────────────►  (còn nhận traffic tới hết t3)
t1                 pod v2 khởi động → Flyway chạy V<n+1> → schema MỚI
t2                 pod v2 Ready ─────────────────────────────────────►
t3   pod v1 bị tắt
          └──── t1..t3: v1 (code cũ) đang chạy trên schema MỚI ────┘
```

Và **rollback ứng dụng không rollback schema**: cd-dev/staging/prod tự quay về image cũ khi smoke fail (ADR-005),
nhưng Flyway không tự "undo" V<n+1> — nghĩa là code cũ chạy tiếp trên schema mới, lần này không có hạn định.

⇒ Mỗi migration phải chạy đúng với **cả code trước nó lẫn code sau nó**. Thứ gì code cũ còn dùng thì migration này
không được làm biến mất hay đổi nghĩa.

## 2. Hai luật của Flyway cần nhớ

1. **Không bao giờ sửa một migration đã có.** Flyway lưu *checksum* của từng file đã áp dụng vào bảng
   `flyway_schema_history`. Sửa dù một dấu cách → mọi Pod khởi động báo `Migration checksum mismatch` và **không lên được**.
   Cần sửa? Thêm migration mới (`V<n+1>`). Checker chặn sửa/xóa/đổi tên file cũ.
2. **Version chỉ tăng.** Hai PR cùng thêm `V3__…` → Flyway từ chối hoặc chạy sai thứ tự. Checker chặn version không
   lớn hơn version cao nhất đã có ở `main`. Xung đột? Rebase rồi đánh số lại.

Về `ddl-auto: validate` (Hibernate kiểm entity ↔ bảng): **cột thừa trong DB không sao** (entity cũ không map tới nó),
**cột entity cần mà DB thiếu thì Pod không khởi động** — vì vậy cột luôn phải được thêm **trước** khi code dùng nó.

## 3. Bảng "được / không được" cho một migration đơn lẻ

| Thao tác | Code cũ + schema mới | Ghi chú / cách làm đúng |
|---|---|---|
| `CREATE TABLE`, `CREATE INDEX` | ✅ | Bảng lớn: `CREATE INDEX CONCURRENTLY` (không chạy được trong transaction mặc định của Flyway — cần file cấu hình đi kèm `V3__x.sql.conf` chứa `executeInTransaction=false`) |
| `ADD COLUMN x TYPE` (nullable) | ✅ | **Bước expand chuẩn.** |
| `ADD COLUMN x TYPE NOT NULL DEFAULT …` | ✅ (PG ≥ 11: chỉ đổi metadata, không viết lại bảng) | Default phải là hằng số |
| `ADD COLUMN x TYPE NOT NULL` (không default) | ❌ | Code cũ `INSERT` không có `x` → lỗi ngay. **Checker: lỗi cứng, không có cách né** |
| `DROP COLUMN` / `DROP TABLE` | ❌ | Code cũ còn `SELECT`/`INSERT` nó. Chỉ làm ở **bước contract** |
| `RENAME COLUMN/TABLE` | ❌ | Là "thêm tên mới + xóa tên cũ" trong một nhát. Làm bằng expand → dual-write → contract |
| `ALTER COLUMN … TYPE` | ⚠️ | Có thể viết lại cả bảng (khóa `ACCESS EXCLUSIVE` — mọi truy vấn xếp hàng) và code cũ đọc/ghi sai kiểu |
| `ALTER COLUMN … SET NOT NULL` | ⚠️ | Code cũ có thể còn ghi `NULL`. Chỉ sau khi **mọi** code đang chạy đã luôn ghi giá trị |
| `TRUNCATE`, `DELETE` hàng loạt | ❌ | Xóa dữ liệu code cũ cần |

Checker (`scripts/check-migrations.sh`) chặn các dòng ❌/⚠️ trong migration **mới**. Với ❌/⚠️ mà bạn *biết* là bước
contract hợp lệ, thêm **một dòng chú thích ở đầu file** để xác nhận có chủ đích (review sẽ thấy nó):

```sql
-- expand-contract: v0.4.0 đã ngừng đọc cột phone ở dev/staging/prod (kiểm 2026-10-15)
ALTER TABLE customers DROP COLUMN phone;
```

## 4. Quy trình đúng: đổi một thứ cần 3 release

Ví dụ "thêm `customers.email_verified BOOLEAN NOT NULL DEFAULT false`":

| Release | Migration | Code | Trạng thái an toàn khi… |
|---|---|---|---|
| **A — expand** | `V2__add_email_verified.sql`: `ALTER TABLE customers ADD COLUMN email_verified BOOLEAN;` (nullable) | **Không đổi** — chưa ai đọc/ghi cột | v1 chạy trên schema mới ✅; rollback về v0 ✅ |
| **B — migrate** | (tùy) backfill: `UPDATE customers SET email_verified = false WHERE email_verified IS NULL;` — bảng lớn thì **chia batch** ngoài Flyway | Entity thêm `emailVerified`; code **luôn ghi** giá trị | A→B: pod A (chưa biết cột) ✅; rollback B→A: A không biết cột ✅ |
| **C — contract** | `V4__email_verified_not_null.sql` có chú thích `expand-contract` : `ALTER COLUMN … SET DEFAULT false`, rồi `SET NOT NULL` | Không đổi | Chỉ an toàn vì mọi pod chạy B trở lên đều luôn ghi giá trị |

Quy tắc ngón tay cái: **chỉ chuyển sang bước sau khi bước trước đã chạy ổn ở MỌI môi trường đích** (dev → staging → prod
theo [cd-promotion.md](cd-promotion.md)). Đó là lý do contract để "vài ngày sau" — không phải cùng PR.

## 5. Lab (dev, ~90 phút)

**Ca 1 — CI bắt migration phá tương thích.**
1. Nhánh mới, thêm `apps/backend/customer-service/src/main/resources/db/migration/V2__drop_phone.sql` với
   `ALTER TABLE customers DROP COLUMN phone_number;`. Mở PR.
2. `ci-backend` job **migration-guard** đỏ, log nêu đúng dòng + cách xử lý. Thêm dòng `-- expand-contract: …`
   và chạy lại: đổi thành cảnh báo. **Đóng PR, đừng merge.**
3. Tự kiểm tra: `git diff origin/main...HEAD -- '*db/migration*'` rồi `./scripts/check-migrations.sh origin/main` chạy được tại máy.

**Ca 2 — Đổi tên cột đúng cách (không downtime).** Mục tiêu: `customers.phone_number` → `customers.phone`.
1. (Expand) `V2__add_phone.sql`: `ALTER TABLE customers ADD COLUMN phone VARCHAR(64);` + code ghi **cả hai** cột, đọc `phone`,
   nếu null thì đọc `phone_number`. Merge → CD dev.
2. (Migrate) migration `UPDATE customers SET phone = phone_number WHERE phone IS NULL;` (bảng nhỏ nên 1 câu là đủ).
3. (Contract, release sau) code chỉ dùng `phone`; `V4__drop_phone_number.sql` có chú thích `expand-contract`.

Trong lúc mỗi release được deploy, chạy vòng lặp này ở một terminal và **kỳ vọng 0 lỗi** (thử với một release cố tình phá tương thích để thấy lỗi):

```bash
HOST=$(kubectl -n bss get ingress bss-ingress -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
while true; do
  code=$(curl -s -o /dev/null -w '%{http_code}' -X POST "http://$HOST/api/tmf-api/customerManagement/v4/customer" \
    -H 'Content-Type: application/json' -d "{\"name\":\"lab\",\"email\":\"lab-$RANDOM@example.com\"}")
  echo "$(date +%T) $code"; sleep 0.5
done
```

**Câu hỏi tự kiểm tra**
1. Ba file `V2__fix_currency_column_type.sql` hiện có (`CHAR(3)` → `VARCHAR(3)`) sẽ bị checker chặn nếu xuất hiện trong một PR mới. Chúng có thật sự nguy hiểm không? Bạn sẽ ghi chú `expand-contract` thế nào cho trung thực?
2. Vì sao "thêm cột NOT NULL không default" là lỗi cứng còn "DROP COLUMN" thì cho phép ghi chú xác nhận?
3. Cd-prod rollback tự động về `prod.json` cũ. Nếu release vừa deploy có `V5` (contract, đã chạy), rollback đưa hệ thống về trạng thái nào? Điều này nói gì về việc **không gộp contract vào cùng release với code mới**?
4. Hai PR cùng thêm `V3__…` vào một service; PR thứ hai merge sau. Điều gì xảy ra ở CI, và xử lý thế nào?
