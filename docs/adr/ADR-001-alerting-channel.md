# ADR-001 — Kênh nhận cảnh báo Alertmanager (Discord/Slack)

- **Trạng thái:** Chấp nhận (Accepted) — treo phần webhook thật (Proposed cho phần đó)
- **Ngày:** 2026-09-15
- **Giai đoạn:** 2 — Kubernetes local (kind) + Observability local

## Bối cảnh

`platform/monitoring/prometheus/values.yaml` (bản AWS) đã có sẵn route Alertmanager
(`group_by`, `group_wait`, `group_interval`, `repeat_interval`) nhưng receiver `"default"`
**rỗng** — chỉ có comment mẫu `# slack_configs: ...` (B-42). Kết quả: 5 alert trong
`bss-alerts.yaml` có thể chuyển `Firing` thật (xác nhận được qua Prometheus/Alertmanager UI) mà
**không ai nhận được thông báo** ở đâu cả — đúng câu hỏi cốt lõi của observability: "thấy lỗi
trước người dùng" chỉ đúng nếu có người thật sự được báo.

Tại thời điểm làm Giai đoạn 2, chưa có webhook Discord hay Slack nào được tạo sẵn.

## Quyết định

1. Viết **cả 2 lựa chọn** (`discord_configs` và `slack_configs`) dưới dạng comment sẵn trong
   `platform/monitoring/prometheus/values-local.yaml`, kèm hướng dẫn từng bước tạo webhook trong
   `docs/runbooks/bss-high-error-rate.md`. Người dùng bỏ comment đúng 1 khối + điền URL thật khi
   sẵn sàng — không chặn phần còn lại của Giai đoạn 2 (metrics/dashboard/alert-rule) vì thiếu
   quyết định "Discord hay Slack".
2. **Không commit URL webhook thật lên git** dù đây chỉ là cluster kind chạy trên laptop cá nhân
   — giữ đúng thói quen production ngay từ đầu (webhook URL cho phép bất kỳ ai có nó gửi tin nhắn
   vào kênh của bạn, tương đương một credential nhẹ). Cách áp dụng không cần commit:
   - Sửa trực tiếp `values-local.yaml` cục bộ (file này **có** commit, nhưng phần webhook luôn ở
     dạng comment/placeholder — sửa xong nhớ không `git add` phần đã điền thật, hoặc dùng
     `git update-index --skip-worktree` nếu muốn giữ file sửa cục bộ vĩnh viễn), hoặc
   - Truyền qua `helm upgrade --set-string 'alertmanager.config.receivers[0].discord_configs[0].webhook_url=...'`
     lúc cài, không đụng file nào cả.
3. Mỗi alert trong `bss-alerts.yaml` có thêm annotation `runbook_url` trỏ tới
   `docs/runbooks/bss-high-error-rate.md` — đúng yêu cầu CLAUDE.md §10 ("Mọi alert có
   `runbook_url` annotation").
4. **Checkpoint của Giai đoạn 2 không yêu cầu webhook thật hoạt động** — chỉ cần xác nhận alert
   chuyển `Firing` trong Alertmanager UI (xem `learning/20` checkpoint: "ép lỗi 500 → alert tới
   Discord/Slack trong ≤ 10 phút" — phần "tới Discord/Slack" là bước người dùng tự hoàn tất khi
   họ chọn kênh và tạo webhook, không phải việc của phiên làm việc này).

## Hệ quả

- ✅ Không có quyết định "Discord hay Slack" nào bị áp đặt — người dùng tự chọn khi sẵn sàng.
- ✅ Không có webhook URL thật nào lộ ra git, kể cả với cluster chỉ chạy local.
- ⚠️ Cho tới khi người dùng tự điền URL thật, alert vẫn "câm" (Firing nhưng không ai nhận được) —
  đây là nợ kỹ thuật **có chủ đích**, ghi rõ trong runbook, không phải bị bỏ quên.
- ⚠️ 2 kênh (Discord/Slack) có cấu trúc `receiver` khác nhau trong Alertmanager — nếu sau này đổi
  kênh, phải tự sửa `values-local.yaml` (không tự động chuyển đổi qua lại).

## Lựa chọn khác đã cân nhắc

1. **Tạo sẵn 1 webhook demo dùng chung** (vd. 1 kênh Discord của lớp học) — bị loại vì webhook
   URL là bí mật riêng của từng người, không nên chia sẻ trong tài liệu công khai của repo.
2. **Email qua SMTP** (Alertmanager hỗ trợ `email_configs` sẵn) — bị loại cho Giai đoạn 2 vì cần
   thêm cấu hình SMTP server (Gmail App Password hoặc SES) phức tạp hơn 1 webhook URL; để dành
   nếu sau này cần kênh dự phòng.
3. **PagerDuty** — đúng chuẩn production hơn (có escalation policy, on-call rotation) nhưng quá
   nặng cho một dự án học tập cá nhân với 1 người nhận cảnh báo.
