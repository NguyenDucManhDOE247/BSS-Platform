# ADR-009 — Không thêm Jenkins / Helm chart / Ansible song song với bộ công cụ hiện tại

- **Trạng thái:** Chấp nhận (Accepted) — chủ repo chọn "bỏ, ghi rõ lý do" 2026-09-29
- **Ngày:** 2026-09-29
- **Giai đoạn:** 8, việc 7 (tùy chọn) — xử lý trong đợt dọn nợ sau Giai đoạn 9

## Bối cảnh

Giai đoạn 8 việc 7 (tùy chọn) đề xuất viết Jenkinsfile / Helm chart / Ansible "để so sánh" với cách
repo đang làm. Chủ repo đã dùng cả 3 công cụ đó trong đồ án tốt nghiệp (Jenkins pipeline 12 stage trên
EC2, Ansible 3 role qua jump host, EKS + NGINX Ingress), nên câu hỏi thật là: **có nên nuôi 2 bộ công
cụ cho cùng 1 việc trong repo này không?**

## Lựa chọn và lý do

| Việc | Repo dùng | Công cụ thay thế | Vì sao không thêm |
|---|---|---|---|
| CI/CD | **GitHub Actions + OIDC** (7 workflow, ADR-005) | Jenkins | Jenkins cần 1 server tự vận hành (EC2 + plugin + backup + bảo mật) và credential AWS trên server đó (instance role). Actions chạy trên runner của GitHub, lấy credential tạm qua OIDC theo từng GitHub Environment (không khóa tĩnh, B-39), có sẵn cổng duyệt tay cho prod. Với 1 người vận hành, server Jenkins là chi phí + bề mặt tấn công thêm mà không mở khóa được khả năng mới. |
| Đóng gói manifest K8s | **Kustomize** (base + 4 overlay + 2 component) | Helm chart | 7 service của **chính repo này**, cấu hình chỉ khác nhau theo môi trường → overlay/patch là đủ, và `kubectl apply -k` có sẵn. Helm mạnh khi **phân phối** gói cho người khác (values API, versioning chart) — repo vẫn dùng Helm đúng chỗ đó: cài addon bên thứ ba (ALB Controller, Secrets CSI, kube-prometheus-stack). Viết thêm chart cho service của mình = 2 nguồn sự thật cho cùng 1 manifest. |
| Cấu hình máy | **Không có máy nào để cấu hình** (container bất biến + Terraform + EKS managed node group) | Ansible | Ansible sinh ra để cấu hình máy chủ đang chạy (cài gói, sửa file, khởi động dịch vụ). Ở đây node là AMI EKS do AWS quản lý, ứng dụng nằm trong image build 1 lần (ADR-005) — không có bước "SSH vào sửa máy" nào để tự động hóa. Thêm Ansible chỉ để có Ansible là ngược với mô hình immutable infrastructure. |

## Quyết định

**Không viết Jenkinsfile / Helm chart cho service / Ansible playbook.** Kiến thức đó đã có ở đồ án; repo
này giữ **1 cách làm cho mỗi việc** và ghi lại tương ứng ở đây để đối chiếu khi review.

## Khi nào nên xem lại

- **Jenkins:** tổ chức bắt buộc CI on-premise / không được dùng runner SaaS, hoặc cần agent trong mạng
  nội bộ (khi đó cân nhắc self-hosted runner của GitHub trước — cùng workflow, không đổi công cụ).
- **Helm chart:** muốn người khác cài BSS vào cluster của họ (phân phối) → chart là giao diện đúng.
- **Ansible:** xuất hiện máy chủ lâu dài phải cấu hình (bastion, VM chạy phần mềm bên thứ ba ngoài K8s).

## Hệ quả

- ✅ 1 nguồn sự thật cho pipeline (`.github/workflows/`) và cho manifest (`infrastructure/kubernetes/`).
- ✅ Không có server CI hay khóa AWS tĩnh nào phải bảo vệ.
- ⚠️ Người quen Jenkins/Helm phải học GitHub Actions/Kustomize khi đọc repo — bảng trên là cầu nối.
