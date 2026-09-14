# 17 — Makefile, scripts bash, quy ước repo

> Mục tiêu bài: đọc hiểu "lớp keo" nối mọi thứ lại — Makefile, 3 script, `.gitignore`, template GitHub, CHANGELOG —
> và sửa B-07, B-38, B-52. Thời lượng: 1–2h đọc + 2h lab. Đọc ở **Giai đoạn 0–1**.

---

## 1. Makefile — từng dòng

🔍 [Makefile](../Makefile)

| Dòng | Code | Giải thích |
|---|---|---|
| 1–4 | `.PHONY: help bootstrap ...` | Khai báo đây là "lệnh" chứ không phải tên file (nếu có file tên `build`, make vẫn chạy target `build`) |
| 6 | `ENV ?= dev` | `?=` gán **nếu chưa được đặt** → ghi đè bằng `make ENV=prod ...` |
| 7 | `AWS_REGION ?= ap-southeast-1` | |
| 8 | `ACCOUNT_ID ?= $(shell aws sts get-caller-identity ...)` | Gọi AWS CLI để lấy account id (🔁 giống stage "Init" Jenkins của bạn). Không đăng nhập AWS → rỗng |
| 9 | `ECR_REGISTRY := ...` | `:=` tính **ngay** một lần (khác `=` tính lại mỗi lần dùng) |
| 10 | `CLUSTER := bss-$(ENV)-eks` | Khớp tên trong Terraform |
| 11 | `TAG ?= $(shell git rev-parse --short HEAD ...)` | Tag = SHA ngắn 7 ký tự. ⚠️ CD dùng SHA **đầy đủ** (`github.sha`) → cùng commit nhưng hai tag khác nhau giữa build tay và build CI |
| 13 | `SERVICE_DIR := $(shell test -d apps/backend/$(SERVICE) && echo ... \|\| echo ...)` | Tự đoán service là backend hay frontend |
| 15–16 | `help:` grep các dòng `target: ## mô tả` rồi awk in đẹp | Mẹo "self-documenting Makefile" — đáng dùng lại |
| 19–30 | `bootstrap`, `local-up/down/reset` | `down -v` xóa volume = xóa dữ liệu Postgres |
| 33–43 | `tf-init/plan/apply/destroy` | `tf-destroy` gọi `teardown.sh` (có xác nhận prod) |
| 46–50 | `kube-config`, `platform-install` | ⚠️ `platform-install` chỉ `echo` (B-60) |
| 53–60 | `ecr-login`, `build`, `push` | `push: ecr-login build` = chạy 2 target kia trước |
| 63–70 | `set-image` (cần binary `kustomize`), `deploy` (`kubectl apply -k` + `rollout status`) | |
| 72–75 | `smoke`, `grafana` (port-forward 3000) | |

Chú ý: recipe trong Makefile **phải thụt bằng TAB**, không phải dấu cách. Mỗi dòng recipe chạy trong một shell riêng (vì vậy dùng `cd x && lệnh` trên cùng dòng).

⚠️ Windows không có `make` → dùng WSL2 (bài 12 mục 0).

---

## 2. Scripts bash — những kỹ thuật cần thuộc

🔁 Handout 2 (Bash scripting): shebang, biến, điều kiện, vòng lặp, tham số `$1`.

| Kỹ thuật | Ở đâu | Ý nghĩa |
|---|---|---|
| `#!/usr/bin/env bash` | cả 3 script | Tìm `bash` theo `PATH` (linh hoạt hơn `/bin/bash`) |
| `set -euo pipefail` | cả 3 | `-e` lỗi là dừng; `-u` dùng biến chưa đặt là lỗi; `pipefail` lỗi ở giữa pipe cũng tính là lỗi |
| `"${AWS_REGION:-ap-southeast-1}"` | bootstrap, smoke | Giá trị mặc định nếu biến rỗng |
| `if aws s3api head-bucket ...; then` | bootstrap | Kiểm tra tồn tại → **idempotent** (chạy lại không lỗi) |
| heredoc `cat > /tmp/budget.json <<EOF` | bootstrap | Sinh file JSON có chèn biến |
| `[[ "$ENV" =~ ^(dev\|staging\|prod)$ ]]` | teardown | Kiểm tra đầu vào bằng regex |
| `read -r confirmation` | teardown | Xác nhận thủ công trước khi phá prod |
| `cd "$(dirname "$0")/..."` | teardown | Chạy được từ bất kỳ thư mục nào |
| `... \|\| echo "failed"` | smoke | ⚠️ **Nuốt lỗi** → script luôn exit 0 (B-52) |

### 2.1 `bootstrap-aws.sh` — xem [bài 14 mục 10](14-terraform-aws.md). Lỗi tên bucket toàn cầu (B-38); `/tmp/budget.json` không xóa sau khi dùng (vô hại).

### 2.2 `teardown.sh`
- Tốt: chặn tham số lạ, xác nhận prod, nhắc bucket state được giữ lại.
- Thiếu: dọn Ingress/NodePool trước (B-37); `-auto-approve` ở mọi env — ⚖️ tiện nhưng nguy hiểm, cân nhắc chỉ auto-approve cho dev.

### 2.3 `smoke.sh` — viết lại theo nguyên tắc
```text
1. Lấy hostname ALB (chờ tối đa N giây, không có → exit 1)
2. GET /api/tmf-api/productCatalog/v4/productOffering → phải 200 và có ≥ 1 phần tử (jq -e)
3. GET /                                              → phải 200 và chứa "<div id=\"root\">"
4. (tùy chọn) tạo customer + order giả → chờ hóa đơn ≤ 60s
5. Bất kỳ bước nào sai → in lý do, exit 1
```
`jq -e` trả exit ≠ 0 khi biểu thức ra `false`/`null` — rất hợp cho kiểm tra trong script.

---

## 3. Quy ước repo & quyền file

| File | Nội dung chính | Việc cần làm |
|---|---|---|
| [.gitignore](../.gitignore) | Nhóm: secret (`.env`, `*.tfvars` trừ `.example`, `*.pem`), Terraform (`.terraform/`, `*.tfstate`, **`.terraform.lock.hcl`**), Java, Node, IDE, `.claude/`, kubeconfig, `course/` | ⚖️ HashiCorp khuyến nghị **commit** `.terraform.lock.hcl` (khóa version provider giữa các máy/CI) → bỏ dòng này khỏi ignore |
| `.gitattributes` | **Chưa có** | Thêm: `* text=auto`, `*.sh text eol=lf`, `*.png binary` (B-07) |
| [CONTRIBUTING.md](../CONTRIBUTING.md) | Conventional Commits: `feat(scope): ...`, `fix`, `docs`, `chore`, `refactor`, `test`, `ci` | Dùng scope là tên service/khu vực: `fix(billing): ...` |
| [PULL_REQUEST_TEMPLATE.md](../.github/PULL_REQUEST_TEMPLATE.md) | Summary, loại thay đổi, service bị ảnh hưởng, cách test | Luôn điền "How to test" — thói quen người review quý nhất |
| `ISSUE_TEMPLATE/*.yml` | Form bug/feature | Tạo issue B-xx bằng form bug |
| [CHANGELOG.md](../CHANGELOG.md) | Keep a Changelog + SemVer, mục `[Unreleased]` | Mỗi PR có ý nghĩa → thêm 1 dòng vào `Unreleased`; khi tag `v0.2.0` → chuyển thành mục phiên bản |
| [SECURITY.md](../SECURITY.md) | Báo lỗ hổng qua kênh riêng | — |
| [CLAUDE.md](../CLAUDE.md) | Quy ước cho Claude Code | Cập nhật mục 13 cho đúng thực tế sau Giai đoạn 1 |

Sửa quyền thực thi (B-07) — chạy trong WSL:
```bash
git update-index --chmod=+x scripts/*.sh deploy/postgres-init/*.sh deploy/localstack-init/*.sh
git commit -m "chore(scripts): restore executable bit on shell scripts"
```

🧠 SemVer: `MAJOR.MINOR.PATCH` — tăng MAJOR khi phá tương thích API, MINOR khi thêm tính năng tương thích, PATCH khi sửa lỗi (🔁 handout 8 "Software Versioning"). Tag `rc-v0.2.0` = release candidate của `v0.2.0`.

---

## 4. Labs

| Lab | Nội dung | Lỗi | Đạt khi |
|---|---|---|---|
| 17.1 | Trong WSL: `make help`; đọc từng target và dự đoán lệnh thật (`make -n <target>` in lệnh mà không chạy) | — | Giải thích được mọi target |
| 17.2 | Thêm `.gitattributes`; khôi phục quyền thực thi | B-07 | `git ls-files -s scripts` hiện `100755` |
| 17.3 | Viết lại `smoke.sh` biết fail; thêm target `make e2e-local` | B-52 | Tắt 1 service → smoke exit 1 |
| 17.4 | Sửa `bootstrap-aws.sh`: tên bucket có account id, budget 100% + forecasted | B-38 | Chạy 2 lần liên tiếp không lỗi |
| 17.5 | Cập nhật CHANGELOG `[Unreleased]` cho mọi thay đổi Giai đoạn 1 | — | — |

## 5. Tự kiểm tra
1. `?=`, `:=`, `=` trong Makefile khác nhau thế nào?
2. `set -o pipefail` thay đổi kết quả của `curl ... | jq .` ra sao khi curl lỗi?
3. Vì sao script bootstrap cần idempotent?
4. Commit hay ignore `.terraform.lock.hcl`? Vì sao?
