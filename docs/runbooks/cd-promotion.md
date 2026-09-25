# Runbook — Promotion: `rc-vX.Y.Z` → staging → `vX.Y.Z` → prod

Thiết kế và lý do: [ADR-005](../adr/ADR-005-nguon-su-that-phien-ban-cd.md) (cơ chế) và
[ADR-006](../adr/ADR-006-staging-prod-ephemeral.md) (staging/prod là cluster riêng, dựng theo buổi).
Runbook này là **cách dùng**; đọc [cd-dev.md](cd-dev.md) trước để hiểu manifest/`deploy-state`.

## 1. Bức tranh

```
main ── commit A ── commit B ── commit C          (mỗi merge → cd-dev tự deploy DEV)
                                   │
              git tag rc-v0.1.0 ───┘  ─► cd-staging:  put-image tag rc-v0.1.0 → deploy STAGING → smoke
                                          PASS → releases/rc-v0.1.0.json  (verified_in: [staging])
                                   │
              git tag v0.1.0   ────┘  ─► cd-prod: [check] rc đã qua staging? cùng commit?
                                          [Approve — người duyệt bấm] → put-image tag v0.1.0 → deploy PROD
```

- **Không build lại.** `rc-v0.1.0` và `v0.1.0` chỉ là thêm *tên* lên cùng 7 image digest (`aws ecr put-image`)
  — thứ chạy ở prod là đúng byte đã chạy ở dev và staging.
- **Cổng bắt buộc:** tag phải nằm trên `main`; prod chỉ nhận rc đã `verified_in: staging`, và tag `v`
  phải trỏ **đúng commit** của rc.

## 2. Cắt một release

```bash
git switch main && git pull
# 1. Chắc chắn commit muốn ship đã được deploy xanh ở dev (CD — dev của commit đó PASS):
gh run list --workflow "CD — dev" --limit 3
# 2. Cắt rc TRÊN COMMIT ĐÓ (mặc định là HEAD)
git tag rc-v0.1.0 && git push origin rc-v0.1.0            # → cd-staging
gh run watch                                               # chọn run "CD — staging"
```

Staging xanh, QA xong:

```bash
git tag v0.1.0 "$(git rev-list -n1 rc-v0.1.0)"             # CÙNG commit với rc — cổng kiểm sẽ chặn nếu khác
git push origin v0.1.0                                     # → cd-prod: job "check" chạy ngay; job "deploy" DỪNG chờ Approve
```

Vào **Actions → CD — prod → run → Review deployments → production → Approve**. Người duyệt nên:
mở phần tóm tắt của run staging tương ứng, kiểm bảng service/tag, rồi mới bấm.

## 3. Cluster staging/prod là ephemeral

Nếu cluster chưa dựng, workflow dừng ở bước `Cluster có tồn tại không?` với hướng dẫn. Cách dựng:
[cd-staging-prod-demo.md](cd-staging-prod-demo.md). Sau khi dựng xong, **chạy lại workflow** — không cần
tag lại: **Actions → CD — staging (hoặc prod) → Run workflow → Use workflow from: Tag → chọn tag**.
Vì desired được tính từ commit của tag, kết quả giống hệt lần đầu.

## 4. Rollback

| Tình huống | Cách |
|---|---|
| Deploy hỏng ngay lúc chạy (rollout/smoke fail) | **Tự động** — workflow áp lại `staging.json`/`prod.json` cũ, run vẫn đỏ. Xem `docs/labs/06-cd-rollback.md` |
| Prod đã PASS nhưng phát hiện lỗi sau đó | Chạy lại workflow prod với **tag của bản tốt trước** (`v0.0.9`): Run workflow → Use workflow from Tag `v0.0.9`. Cổng vẫn đạt vì `releases/rc-v0.0.9.json` còn đó |
| Actions không dùng được | Áp tay bằng manifest: [cd-dev.md §5](cd-dev.md), thay `dev` → `prod`, đọc `releases/v0.0.9.json` |

⚠️ Rollback bằng "chạy lại tag cũ" **không** sửa `main`. Sửa lỗi thật bằng PR mới rồi cắt `v0.1.1`.
⚠️ Schema database: rollback ứng dụng không rollback schema. Migration phải tương thích ngược để bản
cũ chạy được trên schema mới — xem [schema-migration.md](schema-migration.md).

## 5. Xem "prod đang chạy gì?"

```bash
git fetch origin deploy-state
git show origin/deploy-state:prod.json | jq '.release, .source.sha, .services'
git log origin/deploy-state --format='%h %ad %s' --date=short -- prod.json
git show origin/deploy-state:releases/v0.1.0.json | jq '.verified_in'     # ["prod","staging"]
```

## 6. Sự cố thường gặp

| Triệu chứng | Nguyên nhân | Xử lý |
|---|---|---|
| `commit … KHÔNG nằm trong lịch sử của origin/main` | Tag đặt trên nhánh feature/commit chưa merge | Xóa tag (`git push origin :refs/tags/rc-v0.1.0`), merge PR, tag lại trên `main` |
| `Chưa có image trong ECR cho: [...]` (staging) | cd-dev của commit đó chưa chạy/đã lỗi ở bước build | Xem run cd-dev của commit; chạy `workflow_dispatch` cd-dev rồi tag lại/chạy lại |
| `Chưa có releases/rc-vX.json` (prod) | Chưa từng promote rc lên staging (hoặc staging FAIL) | Đặt tag `rc-vX` trên đúng commit, đợi CD staging xanh |
| `chưa được xác nhận trên staging` | Run staging đã fail/rollback nên không ghi `verified_in` | Sửa lỗi, cắt `rc-v0.1.1` |
| `tag trỏ vào <sha> nhưng bản rc đã qua staging ở <sha2>` | Tag `v` và `rc-v` khác commit | `git tag -f v0.1.0 <sha2> && git push -f origin v0.1.0` (chưa deploy prod nên an toàn) |
| `bss/<svc>:rc-vX đã trỏ tới <digest>, khác image …` | Tag ECR là IMMUTABLE — đã có người gắn tên này vào image khác | Dùng số phiên bản mới; **không** xóa/đè tag phát hành |
| `Not authorized to perform sts:AssumeRoleWithWebIdentity` | `sub` của job ≠ trust policy | Job có `environment: X` ⇒ `sub` = `repo:<owner>/<repo>:environment:X`. Kiểm Environment đã tạo, variable `AWS_ROLE_ARN` đúng role của môi trường |
| Job prod đứng ở "Waiting" mãi | Chưa ai Approve (Required reviewers) — đúng thiết kế | Approve, hoặc kiểm người duyệt đã được thêm vào Environment `production` |
| `Tag … is not allowed to deploy to production` | Deployment tag policy của Environment không khớp tên tag | Environment `production` chỉ cho tag `v*` (SETUP.md Part 6) |
