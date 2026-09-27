# tools/ops/ — day-2 operations scripts

Giai đoạn 8, việc 4 (`learning/20-lo-trinh-hoan-thanh.md`). Ba script Python nhỏ, không phụ
thuộc framework nặng (không Ansible/Terraform ở đây — đây là script vận hành chạy tay hoặc từ
CronJob, khác với IaC khai báo hạ tầng). Cài phụ thuộc:

```bash
pip install -r tools/ops/requirements.txt
```

Cả ba đều đọc credentials từ chain mặc định của `boto3` (biến môi trường, `~/.aws/credentials`,
hoặc IRSA nếu chạy trong Pod) — không có access key nào hard-code trong script.

## `cost_report.py` — chi phí AWS gần thời gian thực

```bash
python tools/ops/cost_report.py                       # 7 ngày gần nhất, so với ngân sách $30
python tools/ops/cost_report.py --days 14 --budget 50
python tools/ops/cost_report.py --json                # cho script khác đọc tiếp
```

Dùng Cost Explorer (`ce get-cost-and-usage`), nhóm theo `SERVICE` và theo tag `Environment`. Chỉ
đọc — không tạo/sửa/xóa tài nguyên nào. Chạy vào cuối mỗi buổi học để tự trả lời "hôm nay tốn bao
nhiêu, có quên `terraform destroy` không" thay vì đợi email cảnh báo Budget (có độ trễ ~vài giờ).

⚠️ Cost Explorer tính phí theo API call (rất nhỏ, ~$0.01/request) — không gọi trong vòng lặp.

## `dlq_tool.py` — kiểm tra & khôi phục Dead Letter Queue

```bash
python tools/ops/dlq_tool.py list
python tools/ops/dlq_tool.py peek bss-dev-billing-orders-dlq
python tools/ops/dlq_tool.py redrive bss-dev-billing-orders-dlq --target bss-dev-billing-orders --yes
python tools/ops/dlq_tool.py purge bss-dev-billing-orders-dlq --yes
```

Câu hỏi on-call kinh điển: "billing ngừng xuất hóa đơn — có message nào kẹt trong DLQ không, và
tại sao?" `peek` chỉ đọc (không xóa message — `VisibilityTimeout=5s`), an toàn để chạy bất cứ lúc
nào. `redrive`/`purge` **bắt buộc `--yes`** vì đây là hành động thay đổi trạng thái thật (đẩy lại
message = billing sẽ thử xử lý lại ngay — nếu nguyên nhân gốc vẫn còn, message quay lại DLQ vòng
2; `purge` là xóa vĩnh viễn, mất dữ liệu event nếu chưa điều tra xong).

`redrive` dùng SQS `StartMessageMoveTask` (API redrive gốc, không phải tự viết vòng lặp
receive→send→delete — tránh nguy cơ tự làm trùng/mất message).

## `health_check.py` — bảng UP/DOWN cho cả 5 backend

```bash
# Cách 1 — port-forward từng service rồi chạy local (xem --help để có lệnh port-forward đầy đủ)
python tools/ops/health_check.py --mode local

# Cách 2 — chạy như 1 Pod tạm bên trong cluster, dùng DNS nội bộ, không cần port-forward
kubectl -n bss run health-check --rm -it --restart=Never --image=python:3.12-slim \
  -- sh -c "pip install requests -q && python -c \"$(cat tools/ops/health_check.py)\" --mode cluster"
```

Lý do cần script riêng thay vì "gọi gateway là xong": **api-gateway không tổng hợp health của các
service phía sau** (B-03 — gateway chỉ route đúng path TMF, không có route `/actuator/**` xuyên
qua). Script này hit trực tiếp `/actuator/health` của cả 5 service cùng lúc, in 1 bảng, exit code
`1` nếu có bất kỳ service nào không `UP` — dùng được trong CI/CronJob làm health-gate.
