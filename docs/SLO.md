# SLO — order-management (Giai đoạn 7, việc 4)

> Chọn **1 service** theo đúng phạm vi `learning/20` mục Giai đoạn 7 — `order-management` vì đây
> là bước quan trọng nhất trong hành trình khách hàng (đặt hàng thất bại = mất doanh thu trực
> tiếp, khác với ví dụ latency chậm ở `product-catalog` chỉ gây khó chịu). Nhân rộng cho service
> khác chỉ cần đổi `application="order-management"` trong 2 file alert.

## 1. SLI (Service Level Indicator) — thứ đo được

**Tỉ lệ request KHÔNG phải lỗi 5xx**, đo bằng Micrometer/Prometheus đã có sẵn từ B-16:

```promql
sum(rate(http_server_requests_seconds_count{application="order-management",status!~"5.."}[5m]))
/
sum(rate(http_server_requests_seconds_count{application="order-management"}[5m]))
```

Không đo latency ở đây (đã có alert riêng `BssHighRequestLatency`) — SLO chỉ nên đo **một** chỉ
số quan trọng nhất cho service đó; đo quá nhiều SLI làm loãng ưu tiên khi có sự cố.

## 2. SLO (mục tiêu) và error budget

**Mục tiêu: 99.5% request thành công trong cửa sổ 30 ngày.**

| | |
|---|---|
| SLO | 99.5% |
| Error budget | 100% − 99.5% = **0.5%** |
| Số phút lỗi cho phép / 30 ngày | 0.5% × 43.200 phút = **216 phút** (~3,6 giờ) |
| Vì sao không chọn 99.9%? | 99.9% ⇒ chỉ 43,2 phút/tháng — quá chặt cho 1 dự án học tập, chạy trên node t3, chưa có Karpenter/multi-AZ prod ổn định (B-36 còn treo); 99.5% vẫn đủ nghiêm túc để luyện tư duy SRE mà không tạo báo động giả liên tục. |

**Error budget không phải con số trang trí** — nó là "ngân sách" cho phép: dùng hết ngân sách
tháng này (do 1 sự cố hoặc do release quá nhiều lần gây lỗi nhỏ cộng dồn) thì **dừng ưu tiên tính
năng mới, dồn lực vào ổn định** cho tới khi ngân sách hồi lại (SRE Workbook — Error Budget Policy).
Dự án cá nhân không có "họp ưu tiên" thật, nhưng việc dashboard/alert cho thấy "đã đốt 80% ngân
sách tháng" là tín hiệu thật để tự quyết định: hoãn 1 tính năng, đi sửa nguyên nhân gốc trước.

## 3. Vì sao KHÔNG dùng ngưỡng cứng ("5xx > 5%") mà dùng burn-rate

`BssHighErrorRate` (đã có, Giai đoạn 7 việc 1) là ngưỡng cứng: 5% lỗi trong 5 phút → báo. Vấn đề:
- Không liên hệ gì tới SLO — 5% có thể ĐANG đốt sạch ngân sách tháng trong vài giờ (khẩn cấp) hoặc
  chỉ là 5% của một khoảng traffic cực thấp lúc 3 giờ sáng (không đáng thức dậy).
- Không phân biệt được "sự cố ngắn nhưng dữ dội" với "rò rỉ chậm nhưng dai dẳng" — cả hai đều có
  thể phá SLO tháng nhưng cần phản ứng khác nhau.

**Burn rate** = tốc độ đang tiêu ngân sách lỗi, tính theo bội số của tốc độ "vừa đủ dùng hết đúng
30 ngày": `burn_rate = tỉ_lệ_lỗi_trong_cửa_sổ / error_budget`. Với error budget 0.5%:

| Burn rate | Ý nghĩa | Nếu duy trì liên tục thì đốt hết ngân sách 30 ngày trong |
|---|---|---|
| 1× | Đúng tốc độ SLO cho phép | 30 ngày |
| 6× | Nhanh gấp 6 | 30/6 = 5 ngày |
| 14.4× | Nhanh gấp 14,4 | 30/14,4 ≈ 2 ngày |

## 4. Multi-window burn-rate alert (SRE Workbook, chương "Implementing SLOs")

Một cửa sổ duy nhất luôn phải đánh đổi: cửa sổ ngắn → phát hiện nhanh nhưng dễ báo giả (traffic
thấp/nhiễu); cửa sổ dài → chính xác hơn nhưng phát hiện chậm (đốt hết ngân sách trước khi kịp
báo). Giải pháp chuẩn: **mỗi alert kiểm 2 cửa sổ cùng lúc** (dài để chắc chắn không phải nhiễu,
ngắn để tự "reset" nhanh khi sự cố đã qua — nếu chỉ dùng 1 cửa sổ dài, alert còn Firing rất lâu
sau khi hệ thống đã khỏe lại vì cửa sổ vẫn còn chứa dữ liệu lỗi cũ).

| Alert | Burn rate | Cửa sổ dài | Cửa sổ ngắn | Mức | Ý nghĩa |
|---|---|---|---|---|---|
| `OrderMgmtSloFastBurn` | ≥ 14.4× | 1h | 5m | **critical (page)** | Tốc độ này đốt hết ngân sách **30 ngày** trong **~2 ngày** — cần người xử lý ngay. |
| `OrderMgmtSloSlowBurn` | ≥ 6× | 6h | 30m | **warning (ticket)** | Đốt hết ngân sách trong **~5 ngày** — chưa khẩn cấp bằng đêm nay, nhưng phải xử lý trong vài ngày tới, không để "trôi". |

Cả hai alert **đều dùng AND giữa 2 cửa sổ** — chỉ Firing khi CẢ cửa sổ dài lẫn ngắn cùng vượt
ngưỡng, đúng khuyến nghị của SRE Workbook (giảm thời gian phát hiện xuống ~5 phút cho ca khẩn cấp,
vẫn giữ độ chính xác của cửa sổ dài).

Xem PromQL đầy đủ: `platform/monitoring/alerts/bss-order-management-slo.yaml`. Test đơn vị bằng
`promtool` (không cần cluster): `./scripts/test-alert-rules.sh` — bao gồm kịch bản chứng minh
alert **chỉ** Firing khi cả 2 cửa sổ cùng tệ, không Firing khi chỉ 1 trong 2.

## 5. Việc CHƯA làm (ngoài phạm vi "1 service" của Giai đoạn 7)

- Dashboard Grafana riêng cho SLO/error-budget (panel "ngân sách còn lại tháng này") — có thể
  thêm vào `platform/monitoring/grafana/dashboards/` sau, không chặn checkpoint Giai đoạn 7.
  Ngay bây giờ, số liệu vẫn truy vấn được thủ công bằng PromQL ở mục 1.
- Nhân rộng SLO cho 4 service Java còn lại — làm khi có nhu cầu thật (Giai đoạn 8 trở đi), tránh
  tạo hàng chục alert chưa ai từng nhìn qua một lần.
- Error Budget Policy chính thức (ai duyệt dừng tính năng khi đốt hết ngân sách) — không cần thiết
  cho dự án cá nhân solo, nhưng đáng nói trong phỏng vấn (xem `learning/30-on-tap-flashcards.md`
  mục I câu hỏi phỏng vấn).
