# Nhật ký học tập

> Ghi **mỗi buổi** (5 phút). Khi quay lại sau thời gian dài, đọc 10 mục cuối trước tiên.
> Mẫu bên dưới — sao chép lên đầu danh sách cho buổi mới (mới nhất ở trên cùng).

---

## Mẫu

```markdown
### YYYY-MM-DD — Giai đoạn N — (thời lượng)
- **Đã làm:** (lab/PR/issue — link)
- **Hiểu ra (Feynman 3–5 dòng):**
- **Còn mơ hồ:**
- **Lỗi gặp + cách xử lý:**
- **Lần sau làm:**
- **Ôn flashcard:** mục __, đúng __/__ (lịch ôn tiếp: +__ ngày)
```

---

## Lịch ôn tập (spaced repetition)

| Bài | Ngày học | +1 | +3 | +7 | +21 | +60 |
|---|---|---|---|---|---|---|
| 00 Tổng quan | | | | | | |
| 01 Hiện trạng | | | | | | |
| 02 Cầu nối | | | | | | |
| 10 Backend | | | | | | |
| 11 Frontend | | | | | | |
| 12 Docker/local | | | | | | |
| 13 K8s/Kustomize | | | | | | |
| 14 Terraform/AWS | | | | | | |
| 15 CI/CD | | | | | | |
| 16 Platform/Obs | | | | | | |
| 17 Makefile/scripts | | | | | | |

---

## Quyết định kiến trúc đã chốt (tóm tắt, chi tiết ở docs/adr/)

| ADR | Chủ đề | Quyết định | Ngày |
|---|---|---|---|
| 000 | Cách chạy local | | |
| 001 | Mạng dev (NAT/endpoint/public) | | |
| 002 | Nguồn sự thật phiên bản (CD) | | |
| 003 | Staging/prod với ngân sách | | |

---

## Các buổi học

### 2026-09-14 — Giai đoạn 0 — dựng môi trường + mở PR đầu tiên (~2 giờ, làm cùng Claude Code)

- **Đã làm:**
  - Kiểm kê toàn bộ tool đã có trên máy Windows (node, docker, git, kubectl, terraform, aws-cli) và tool còn thiếu (JDK, Maven, helm, kind, jq, yq, trivy, gh).
  - Sửa git identity **local** của repo (đang bị đè bởi `user.name=ngocta`/email của thầy) → về đúng global `NguyenDucManhDOE247` / `ducmanhnguyen247@gmail.com`.
  - Xác nhận qua GitHub API: `NguyenDucManhDOE247/BSS-Platform` **không phải fork** (`"fork": false`) — đã độc lập với `gemmy94/bss-platform` từ trước, không cần thao tác gì thêm.
  - Cài **WSL2 Ubuntu 26.04** (`wsl --install -d Ubuntu`), tạo user Linux `manh`.
  - Cài **Docker Desktop WSL Integration** cho Ubuntu (Settings → Resources → WSL Integration) — xác nhận `docker version` chạy được từ trong WSL.
  - Clone repo vào `~/code/bss-platform` trong WSL (filesystem ext4, không phải `/mnt/c`), set git identity trong WSL, cài extension **VS Code Remote-WSL**.
  - **Sửa B-07**: `git update-index --chmod=+x` khôi phục `100755` cho 5 file `.sh` (`scripts/bootstrap-aws.sh`, `scripts/smoke.sh`, `scripts/teardown.sh`, `deploy/localstack-init/01-bootstrap.sh`, `deploy/postgres-init/01-create-databases.sh`) + thêm `.gitattributes` (`*.sh text eol=lf`) → mở [PR #1](https://github.com/NguyenDucManhDOE247/BSS-Platform/pull/1) → **bạn tự review "Files changed" + tự bấm Squash and merge** (PR luyện tập đầu tiên).
  - Cài `gh` CLI trên Windows, đăng nhập OAuth (scope `repo, project, read:org, gist`).
  - Tạo 10 label (`P0`,`P1`,`P2`,`area/build`,`area/backend`,`area/kubernetes`,`area/terraform`,`area/platform`,`area/cicd`,`area/docs`) + **44 GitHub Issue** cho toàn bộ danh sách lỗi B-xx (trừ B-07 đã fix) — [#2 → #45](https://github.com/NguyenDucManhDOE247/BSS-Platform/issues).
  - Tạo **Project board** "BSS Platform — Hoàn thiện" (Todo/In Progress/Done), add cả 44 issue + PR #1 vào board.
  - Bật **branch protection cho `main`**: chặn force-push + xoá nhánh, bắt buộc qua PR, bắt buộc resolve hết review conversation trước khi merge; không bật `enforce_admins`, không bắt buộc số approval (vì làm solo).
  - Soạn script `~/setup-wsl-dev-tools.sh` (đã copy sẵn vào WSL) cài JDK 21, Maven, nvm+Node 20, kubectl v1.37, kind v0.33.0, helm, Terraform 1.16.2, AWS CLI v2, jq, yq, trivy, gh — **bạn cần tự chạy** (`bash ~/setup-wsl-dev-tools.sh`) vì bước này cần nhập sudo password, Claude không thể/không nên nhập hộ.
  - Phát hiện + xử lý luôn 1 lỗi phát sinh: `core.filemode=true` trên Windows khiến `git status` báo "modified" giả (mất quyền thực thi) cho 5 file `.sh` mỗi lần checkout dù nội dung không đổi → set `core.filemode=false` cho repo trên máy Windows.

- **Hiểu ra (Feynman 3–5 dòng):**
  - Git identity có 2 tầng: **global** (mặc định mọi repo) và **local** (đè riêng cho 1 repo, nằm trong `.git/config`) — `git config --unset` ở local để tầng global lộ ra lại.
  - WSL2 là **userspace Linux tách biệt hoàn toàn** khỏi Windows (PATH, quyền thực thi file, filesystem riêng) — nên "đã cài trên Windows" không có nghĩa là "dùng được trong WSL", và ngược lại. Docker Desktop là ngoại lệ vì daemon của nó chạy chung, chỉ cần bật "WSL Integration" để 2 bên cùng gọi được 1 Docker engine.
  - Executable bit (`chmod +x`) là một phần **mode** được Git lưu trong chính object của nó (100755 vs 100644), tách biệt hoàn toàn với **line ending** (LF/CRLF) — hai lỗi B-07 nhìn giống nhau (đều do Windows) nhưng là 2 cơ chế khác nhau, sửa bằng 2 cách khác nhau (`update-index --chmod` vs `.gitattributes`).
  - Branch protection + Pull Request là cơ chế **bắt buộc mọi thay đổi đi qua review trước khi vào `main`**, kể cả khi làm một mình — giá trị chính là buộc bạn (hoặc CI) tự soát lại diff một lần nữa trước khi nó thành vĩnh viễn trong lịch sử.
  - "Squash and merge" gộp nhiều commit nháp của 1 PR thành đúng 1 commit sạch trên `main` — phù hợp làm solo vì `git log` dễ đọc, dễ revert theo từng bug.
  - Ghim version cụ thể (không phải `latest` trôi tự do) là để **tái lập được** môi trường ở bất kỳ thời điểm nào sau này — nhưng số ghim đó nên là bản mới nhất **tại lúc ghim**, không phải cố tình chọn bản cũ.

- **Còn mơ hồ:**
  - Chưa tự tay chạy `setup-wsl-dev-tools.sh` nên chưa thấy JDK/Maven/kubectl/kind/helm/terraform/awscli/trivy thật sự chạy trong WSL.
  - Chưa thử tạo PR thứ 2 (cho 1 bug B-xx thật) để tự làm lại trọn vòng lặp mà không có Claude cầm tay từng bước.
  - Chưa đọc kỹ `learning/00` và `learning/01` (mới được Claude tóm tắt lại, chưa tự đọc hết).

- **Lỗi gặp + cách xử lý:**
  - `git add --renormalize` vô tình **reset lại** mode `+x` vừa set (renormalize chạy sau làm mất chmod chạy trước) → phải chạy lại `git update-index --chmod=+x` **sau cùng**, ngay trước khi commit.
  - `core.filemode=true` trên Windows gây báo "modified" giả mỗi lần checkout → set `core.filemode=false`.
  - `wsl --install -d Ubuntu` mặc định tự mở OOBE tương tác (hỏi username/password) — dùng `--no-launch` để tránh treo, rồi để chính bạn tự mở app Ubuntu hoàn tất bước đó.
  - Token `gh auth login` mặc định thiếu scope `project` → phải `gh auth refresh -s project` (thêm 1 lần xác thực nữa qua trình duyệt) mới tạo được Project board.

- **Lần sau làm:**
  - Chạy `bash ~/setup-wsl-dev-tools.sh` trong Ubuntu, dán lại bảng version cuối cùng.
  - Checkpoint Giai đoạn 0 theo `learning/00` mục 0: `java -version` (21), `mvn -v`, `docker run hello-world`, `kind version`, `make help` — tất cả chạy được **trong WSL**.
  - Bắt đầu đọc `learning/00-tong-quan-du-an.md` rồi `learning/01` (đã có sẵn, rất chi tiết) trước khi động vào Phase 1 (chạy local end-to-end).

- **Ôn flashcard:** chưa tới, để buổi sau khi bắt đầu đọc bài 00.

---

### 2026-09-10 — Giai đoạn 0 — khởi động
- **Đã làm:** Nhận bộ sổ tay `learning/`, danh sách lỗi B-xx, lộ trình 9 giai đoạn.
- **Lần sau làm:** Đọc 00 → 01 → 02 → 20; cài WSL2; chuẩn bị câu hỏi cho thầy (bài 20 mục 11).
