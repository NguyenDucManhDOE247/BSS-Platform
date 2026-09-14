# 📘 Sổ tay học tập BSS Platform — "Từ gốc đến ngọn"

> Bộ tài liệu này được viết riêng cho người **nhận lại** dự án `bss-platform` và muốn hiểu nó
> như một kỹ sư chứ không phải người "chạy lệnh theo hướng dẫn".
> Viết ngày **2026-09-10**, dựa trên việc đọc **toàn bộ** repo + chạy thử `terraform init/validate/fmt`,
> `kubectl kustomize` trên máy, và đối chiếu với đồ án tốt nghiệp + bộ handout DevOps Bootcamp của bạn.

---

## 1. Thư mục này khác gì `course/` của thầy?

| | `course/` (của thầy, đang bị `.gitignore`) | `learning/` (sổ tay này) |
|---|---|---|
| Bản chất | **Đề cương** 15 module: mục tiêu + lab + checkpoint | **Giáo trình giải thích**: từng file, từng dòng quan trọng, vì sao |
| Giả định | Code trong repo đã chạy đúng | Đã **kiểm chứng**: nhiều phần chưa chạy được — có danh sách lỗi cụ thể |
| Người học | Học viên chung chung | **Bạn** — người đã làm đồ án OSM (Node/Jenkins/Ansible/EKS) + Bootcamp |
| Dùng thế nào | Làm lab theo module | Đọc bài → làm lab → sửa lỗi thật trong repo → ôn tập |

👉 Hai bộ **bổ sung** cho nhau. Khi làm lab trong `course/`, mở bài tương ứng trong `learning/` để hiểu sâu và biết trước chỗ nào sẽ vỡ.

---

## 2. Thứ tự đọc (rất quan trọng)

> **Về cách đánh số file** — số file **KHÔNG** phải thứ tự đọc, mà là **nhóm chủ đề**. Không có file nào bị thiếu; các khoảng trống (`03`–`09`, `18`–`19`, `21`–`29`) là cố ý chừa chỗ để chèn bài mới sau này mà không phải đổi tên hàng loạt.
>
> | Dải | Nhóm | File hiện có |
> |---|---|---|
> | `0x` | **Nhập môn** — đọc trước tiên, theo đúng thứ tự | `00` tổng quan · `01` hiện trạng & lỗi · `02` cầu nối kiến thức |
> | `1x` | **Bài chuyên sâu** — mỗi bài một mảng, đọc *đúng lúc* lộ trình cần | `10` backend · `11` frontend · `12` docker · `13` k8s · `14` terraform · `15` ci/cd · `16` platform · `17` makefile |
> | `2x` | **Quy trình** — kim chỉ nam hàng tuần | `20` lộ trình hoàn thành |
> | `3x` | **Ôn tập** | `30` flashcards |
> | (không số) | **Tài liệu sống** — sửa liên tục | `README.md` (file này) · `nhat-ky-hoc-tap.md` |
>
> Thứ tự **đọc** thì như bảng dưới đây (`20` được đọc sớm, ngay sau 3 bài nhập môn).

| # | File | Đọc khi nào | Thời lượng |
|---|---|---|---|
| 1 | [00-tong-quan-du-an.md](00-tong-quan-du-an.md) | **Đầu tiên.** Dự án là gì, chạy thế nào, mọi thư mục/file để làm gì | 2–3h |
| 2 | [01-hien-trang-va-danh-sach-loi.md](01-hien-trang-va-danh-sach-loi.md) | Ngay sau đó. Thầy làm đến đâu, cái gì thật sự chạy, **danh sách lỗi B-xx** | 2h |
| 3 | [02-cau-noi-kien-thuc.md](02-cau-noi-kien-thuc.md) | Nối kiến thức đồ án + Bootcamp của bạn vào dự án; những gì nên bổ sung | 2–3h |
| 4 | [20-lo-trinh-hoan-thanh.md](20-lo-trinh-hoan-thanh.md) | Lộ trình 9 giai đoạn để hoàn thành dự án — **kim chỉ nam hàng tuần** | 1h |
| 5 | Các bài chuyên sâu `10`→`17` | Đọc **đúng lúc** giai đoạn lộ trình yêu cầu (không đọc hết một lúc) | mỗi bài 3–8h |
| 6 | [30-on-tap-flashcards.md](30-on-tap-flashcards.md) | Ôn định kỳ (xem mục 4) | 20 phút/lần |
| 7 | [nhat-ky-hoc-tap.md](nhat-ky-hoc-tap.md) | Ghi **mỗi buổi học** | 5 phút/buổi |

### Các bài chuyên sâu

| Bài | Chủ đề | Liên quan Bootcamp | Liên quan đồ án của bạn |
|---|---|---|---|
| [10](10-backend-java-spring.md) | Backend Java 21 + Spring Boot, Outbox, Idempotent consumer | 4 Build Tools, Bonus DB | Node.js/Express 4 service |
| [11](11-frontend-react-vite.md) | Frontend React + Vite + Nginx | 4 Build Tools (npm) | Vue 3 + Vite |
| [12](12-docker-va-local-dev.md) | Dockerfile, docker-compose, LocalStack | 7 Docker | 6 image `node:22-alpine` / `nginx:alpine` |
| [13](13-kubernetes-kustomize.md) | Kubernetes manifests + Kustomize 3 môi trường | 10 Kubernetes | namespace `osm`/`osm-dev`, HPA, NGINX Ingress |
| [14](14-terraform-aws.md) | Terraform 7 module + AWS (VPC, EKS, IRSA, RDS, SQS…) | 9 AWS, 11 EKS, 12 Terraform | 5 module vpc/iam/ecr/eks/ec2 |
| [15](15-cicd-github-actions.md) | GitHub Actions + OIDC + promotion | 8 Jenkins, 3 Git | Jenkins 12 stage |
| [16](16-platform-addons-observability.md) | Helm addons, Prometheus Operator, Grafana, Fluent Bit, OTel, Karpenter | 10 Helm, 16 Prometheus | Prometheus annotations + Grafana |
| [17](17-makefile-scripts-repo.md) | Makefile, scripts bash, quy ước repo | 2 Linux, 3 Git, 14 Automation | Python boto3 scripts |

---

## 3. Ký hiệu dùng trong sổ tay

| Ký hiệu | Nghĩa |
|---|---|
| 🧠 | Khái niệm mới — đọc chậm |
| 🔁 | **Nhớ lại** — kiến thức bạn đã học ở Bootcamp/đồ án, được nối vào đây |
| 🔍 | Đọc code — giải thích từng dòng |
| ⚠️ **B-xx** | Lỗi/bẫy đã phát hiện (tra mã ở [01](01-hien-trang-va-danh-sach-loi.md)) |
| 🛠️ | Lab — tự làm trên máy |
| ⚖️ | Trade-off — không có đáp án "đúng tuyệt đối" |
| 💰 | Có phát sinh chi phí AWS |
| ❓ | Tự kiểm tra — trả lời được mới đi tiếp |

---

## 4. Cách học để **không quên** sau 1–2 tháng

Não quên theo "đường cong lãng quên": sau 1 tuần không ôn, bạn nhớ ~20–30%. Cách chống:

1. **Ôn ngắt quãng (spaced repetition).** Sau khi học xong một bài, ôn phần flashcard tương ứng vào ngày **+1, +3, +7, +21, +60**. Mỗi lần chỉ 15–20 phút. Ghi ngày ôn vào [nhật ký](nhat-ky-hoc-tap.md).
2. **Kỹ thuật Feynman.** Cuối mỗi bài, giải thích lại bằng lời của bạn (viết 5–10 dòng vào nhật ký) như đang dạy một bạn năm 2. Chỗ nào ấp úng = chỗ chưa hiểu.
3. **Học bằng tay, không bằng mắt.** Mỗi khái niệm phải gắn với một lần *gõ lệnh/sửa code thật*. Sổ tay này cố ý để bạn **tự sửa** các lỗi B-xx thay vì sửa sẵn.
4. **Một nhánh git cho một lỗi.** Commit message của bạn chính là nhật ký kỹ thuật. Sau 2 tháng, `git log --oneline` kể lại hành trình.
5. **Khi quay lại sau thời gian dài**, làm theo đúng thứ tự:
   - Đọc lại mục "Tóm tắt 1 trang" ở đầu [00](00-tong-quan-du-an.md) và bảng trạng thái ở [01](01-hien-trang-va-danh-sach-loi.md).
   - Đọc 10 dòng cuối [nhật ký](nhat-ky-hoc-tap.md) → biết mình đang dừng ở đâu.
   - Làm lại **một** lab gần nhất đã pass (khởi động tay).
   - Làm flashcard của giai đoạn đang học.

---

## 5. Làm việc cùng Claude Code như một "người kèm cặp"

Sổ tay được thiết kế để bạn học **cùng** Claude chứ không nhờ Claude làm hộ. Một số câu lệnh mẫu:

```text
Dạy tôi bài 13 phần "Probes". Giải thích ngắn, rồi hỏi tôi 5 câu, chấm điểm và giải thích chỗ sai.
```
```text
Tôi đang sửa lỗi B-10 (billing @Transactional). Đừng sửa hộ. Hãy review cách tôi định làm: <mô tả>.
```
```text
Tôi vừa sửa xong B-01. Viết cho tôi 3 câu hỏi phỏng vấn về multi-stage Dockerfile dựa trên chính code tôi đã sửa.
```
```text
Tôi quay lại sau 6 tuần. Đọc learning/nhat-ky-hoc-tap.md và git log, tóm tắt tôi đang ở đâu và nên làm gì tiếp.
```

> Mẹo: Claude có "bộ nhớ" về bạn và hiện trạng dự án, nên các phiên sau không cần giải thích lại từ đầu.

---

## 6. Tiến độ tổng thể (tự đánh dấu)

- [ ] Đọc xong 00, 01, 02, 20
- [ ] Giai đoạn 0 — Chuẩn bị môi trường (WSL2, JDK 21, Maven, kind, helm)
- [ ] Giai đoạn 1 — Local chạy thật end-to-end
- [ ] Giai đoạn 2 — Kubernetes local (kind) + Observability local
- [ ] Giai đoạn 3 — CI xanh trên GitHub
- [ ] Giai đoạn 4 — Sửa Terraform + bootstrap AWS
- [ ] Giai đoạn 5 — Deploy dev lên EKS
- [ ] Giai đoạn 6 — CD dev → staging → prod
- [ ] Giai đoạn 7 — Observability + Security hardening trên AWS
- [ ] Giai đoạn 8 — Reliability, load test, tài liệu, demo

Chi tiết từng giai đoạn: [20-lo-trinh-hoan-thanh.md](20-lo-trinh-hoan-thanh.md).
