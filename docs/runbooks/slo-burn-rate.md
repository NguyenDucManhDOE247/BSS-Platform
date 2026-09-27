# Runbook: SLO burn-rate cao (`OrderMgmtSloFastBurn`, `OrderMgmtSloSlowBurn`)

> Nền tảng: `docs/SLO.md` (SLI, SLO 99.5%/30 ngày, error budget, vì sao dùng multi-window
> burn-rate). Runbook này chỉ nói **phải làm gì** khi alert Firing.

## 1. Biết đang cầm alert nào

| Alert | Mức | Ý nghĩa | Thời gian còn lại nếu không xử lý |
|---|---|---|---|
| `OrderMgmtSloFastBurn` | **critical (page — xử lý ngay)** | Đốt ngân sách 30 ngày trong ~2 ngày | Vài giờ tới trước khi ngân sách cạn hẳn nếu đúng tốc độ này |
| `OrderMgmtSloSlowBurn` | **warning (ticket — vài ngày tới)** | Đốt ngân sách 30 ngày trong ~5 ngày | Vài ngày |

Cả hai có thể **cùng Firing** (sự cố nặng vượt cả 2 ngưỡng) — xử lý theo `FastBurn` trước, đó là
alert khẩn cấp hơn.

## 2. Xác nhận không phải báo động giả

```promql
# So trực tiếp với ngưỡng trong alert (0.072 cho FastBurn, 0.03 cho SlowBurn)
order_management:error_ratio:rate5m
order_management:error_ratio:rate1h
order_management:error_ratio:rate30m
order_management:error_ratio:rate6h
```

Cả 2 cửa sổ (dài + ngắn) của alert đang Firing đều phải vượt ngưỡng — nếu chỉ 1 cửa sổ vượt,
alert sẽ KHÔNG Firing (đúng thiết kế multi-window, xem `docs/SLO.md` mục 4). Nếu bạn thấy giá trị
kỳ lạ (ví dụ cả 4 cửa sổ đều = 0 hoặc không có dữ liệu), khả năng ServiceMonitor chưa scrape được
— xem `docs/runbooks/alerting-setup.md` mục 4.

## 3. Đây thực chất vẫn là `BssHighErrorRate`/`BssServiceDown` — đi tìm nguyên nhân

Burn-rate KHÔNG phải một loại lỗi mới — nó chỉ là cách đo "mức độ nghiêm trọng theo ngân sách SLO"
của những lỗi 5xx đã có. Chẩn đoán y hệt `docs/runbooks/bss-high-error-rate.md` (mục 2-4): đọc
log `order-management`, kiểm phụ thuộc (RDS, EventBridge/SQS, product-catalog qua B-13), xem có
vừa deploy gì không.

## 4. Nếu ngân sách đã đốt gần hết trong tháng

```promql
# Ước lượng % ngân sách 30 ngày đã đốt tính tới giờ, dựa trên tỉ lệ lỗi trung bình 30 ngày qua
(sum(increase(http_server_requests_seconds_count{application="order-management",status=~"5.."}[30d]))
 / sum(increase(http_server_requests_seconds_count{application="order-management"}[30d])))
/ 0.005 * 100
```

Ra > 100 nghĩa là đã đốt VƯỢT ngân sách tháng — không phải lỗi tính toán, nghĩa là SLO 99.5% đã bị
phá thật trong 30 ngày qua. Theo Error Budget Policy (dự án cá nhân không có quy trình duyệt
chính thức, nhưng áp dụng tinh thần): **tạm dừng thêm tính năng mới cho order-management, ưu tiên
sửa nguyên nhân gốc + viết postmortem** trước khi tiếp tục — xem `docs/SLO.md` mục 2.

## 5. Sau khi hết Firing

- Cả `rate5m` VÀ `rate1h` (hoặc `rate30m`/`rate6h`) cùng về dưới ngưỡng → alert tự `Resolved`.
- Ghi lại sự cố vào `docs/POSTMORTEMS.md` nếu đã đốt > 20% ngân sách tháng trong 1 lần — đủ lớn để
  đáng phân tích nguyên nhân gốc, không chỉ "đã hết Firing thì thôi".

## 6. Tự kiểm tra

1. Vì sao `OrderMgmtSloFastBurn` KHÔNG Firing khi chỉ cửa sổ 5 phút vượt ngưỡng (cửa sổ 1h vẫn khỏe)?
2. `burn_rate = 1` nghĩa là gì? Nếu hệ thống duy trì đúng `burn_rate = 1` suốt 30 ngày, SLO có bị phá không?
3. Vì sao dùng `sum(rate(...))` mà không phải `avg(rate(...))` khi tính tỉ lệ lỗi?
