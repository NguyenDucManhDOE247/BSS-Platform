# Lab 09 — Khôi phục RDS về một thời điểm (PITR) sau sự cố dữ liệu

> "Backup chưa từng restore = chưa có backup" (learning/02 mục 5.10). Lab này **restore thật** trên dev EKS +
> RDS, đo thời gian, và ghi lại cả chỗ lab tự vấp. Chạy: `./scripts/lab-rds-pitr.sh dev` (dev đã apply +
> deploy). 💰 ~$0.01 (instance `db.t3.micro` tạm sống ~20 phút).

## 1. Kịch bản

Một lệnh SQL chạy nhầm **không có `WHERE`**: `UPDATE product_offering SET price_amount = 0;` — mọi gói cước về
0₫, khách thấy ngay trên API. Đây là loại sự cố backup sinh ra để cứu: hạ tầng không hỏng gì, dữ liệu thì sai.

**Vì sao không "rollback cả DB"** (restore đè lên instance đang chạy): mọi thứ ghi **sau** mốc khôi phục —
đơn hàng, khách mới đăng ký, hóa đơn — sẽ mất. Cách đúng:

1. **Point-in-time restore SANG INSTANCE MỚI** ở thời điểm ngay trước sự cố.
2. Đọc dữ liệu đúng từ instance đó, **sửa đúng cột bị hỏng** trên DB đang chạy, trong 1 transaction.
3. Xóa instance tạm.

## 2. Điều kiện để PITR được

| Điều kiện | Ở repo này |
|---|---|
| Automated backup bật (`BackupRetentionPeriod ≥ 1`) | dev 1 ngày, staging 7, prod 30 (`modules/rds`) |
| Mốc khôi phục ≤ `LatestRestorableTime` | RDS đẩy WAL lên S3 ~5 phút/lần → mốc mới nhất luôn **trễ tới ~5 phút** so với hiện tại |
| Instance mới vào được mạng cũ | dùng **cùng** DB subnet group + security group + parameter group của instance gốc |
| Người chạy SQL có quyền | dùng **tài khoản của service** (`product-db-credentials`), không dùng master (master/`rds_superuser` không đọc được bảng do `product_svc` sở hữu) |

## 3. Kết quả chạy thật (dev, 2026-10-01)

| Bước | Giờ (UTC+7) | Ghi chú |
|---|---|---|
| Ảnh chụp giá (bước 2) | 18:46 | 4 gói: 99.000 · 199.000 · 299.000 · 29.000 |
| Mốc khôi phục `T_GOOD` | 18:47:17 | 1 phút trước sự cố |
| **Sự cố** | 18:48:17 | `UPDATE 4` — API trả `priceAmount: 0.00` cho mọi gói |
| `LatestRestorableTime` vượt `T_GOOD` | 18:52 | chờ **~4 phút** (đúng nhịp ~5 phút của RDS) |
| `restore-db-instance-to-point-in-time` → `available` | 18:52 → 19:07 | **879 giây (~14,6 phút)** cho DB vài chục MB — phần lớn là thời gian tạo instance, không tỉ lệ với dữ liệu |
| Bản khôi phục khớp ảnh chụp | 19:07–19:11 | khớp **từng dòng** |
| Sửa trên DB đang chạy (1 transaction, 4 `UPDATE … WHERE id = …`) | 19:11:24 | API về đúng giá |
| Xóa instance tạm | 19:15 | `--skip-final-snapshot --delete-automated-backups` |

**Thời gian khách thấy giá sai: ~23 phút**, trong đó ~4 phút chờ WAL + ~15 phút RDS dựng instance — tức **~20 phút
là sàn** của cách khôi phục này trên RDS, kể cả khi người vận hành không chậm giây nào. Đó là con số cần ghi vào
runbook / SLO, không phải "vài phút".

## 4. Chỗ lab tự vấp (giữ lại vì là bài học thật)

1. **Pod lab bị PSS `restricted` từ chối** ở lần chạy đầu: `kubectl run --overrides` không áp securityContext.
   Đổi sang manifest đầy đủ — cổng bảo mật làm đúng việc của nó, kể cả với công cụ của chính mình.
2. **Karpenter đuổi Pod lab giữa chừng** (11:49:29 UTC, `Evicted pod: Underutilized`): node Spot còn sót từ đợt
   load test trước bị gom, Pod trần (không controller) cũng bị evict → lab chết ở bước 6 trong khi **DB đang
   chạy vẫn đang sai giá**. Sửa: annotation `karpenter.sh/do-not-disrupt: "true"` cho mọi tác vụ chạy lâu trên
   cụm có Karpenter (Job migrate, backup, lab). Bước 6–8 được chạy tiếp tay với ảnh chụp đã ghi ở bước 2 — chính
   vì script **in ảnh chụp ra trước khi gây sự cố**, việc cứu không phụ thuộc vào Pod còn sống.

## 5. Nối với runbook / đồ án

- 🔁 Đồ án OSM có `backup_mongodb.py` (dump định kỳ ra S3) — chưa từng có bước restore. RDS làm phần backup tự
  động; phần **đáng luyện** là restore + sửa có chọn lọc như ở đây.
- Khi sự cố là **mất cả instance** (không phải dữ liệu sai): restore mới rồi **đổi endpoint** (Secrets Manager →
  CSI → restart Pod), không sửa từng dòng.
- `tools/ops/orphan_finder.py` bắt được instance `bss-*` nào còn sót nếu lab dừng giữa chừng.

## 6. Tự kiểm tra

1. Vì sao không restore đè lên instance đang chạy?
2. Vì sao mốc khôi phục mới nhất luôn trễ vài phút so với "bây giờ"?
3. Sự cố xảy ra lúc 10:00, phát hiện lúc 10:30. Bạn chọn mốc khôi phục nào, và mất những gì nếu chọn 10:30?
4. Vì sao lab chạy SQL bằng tài khoản `product_svc` thay vì master?
5. Vì sao Pod chạy lâu trên cụm có Karpenter cần `karpenter.sh/do-not-disrupt`?
