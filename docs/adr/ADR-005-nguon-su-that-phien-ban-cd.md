# ADR-005 — Nguồn sự thật về phiên bản đang chạy (CD): "desired từ git" + release manifest

- **Trạng thái:** Chấp nhận (Accepted)
- **Ngày:** 2026-09-25
- **Giai đoạn:** 6 — CD: dev tự động, promotion staging → prod
- **Liên quan:** B-50, B-51, B-52, B-54 · thay thế phần "Promotion" cũ trong CLAUDE.md §5

## Bối cảnh

Câu hỏi cốt lõi của mọi pipeline CD: **"ở môi trường X, service Y đang chạy image nào — và thông
tin đó được lưu ở đâu?"** Bản `cd-dev.yml`/`cd-staging.yml` ban đầu trả lời là "không ở đâu cả", và
hậu quả là 2 lỗi nền tảng:

- **B-50** — `kustomize edit set image` chỉ sửa file *trong runner* (không commit), rồi
  `kubectl apply -k` **cả overlay**. Service không đổi trong commit này bị apply lại với tag nằm
  trong git (`dev`/`CHANGE_ME`) → sai image hoặc `ImagePullBackOff`.
- **B-51** — cd-dev chỉ build service **thay đổi** (tag = SHA của commit đó); cd-staging re-tag
  "image của SHA mà tag trỏ tới" → 5–6 service không có image ở SHA đó, bị `skip` nhưng vẫn bị set
  `:rc-vX` → `ImagePullBackOff`. "Build once, deploy many" gãy khi kết hợp với path-filter.

`learning/20` đề xuất **phương án A — GitOps-lite**: bot commit `overlays/dev/kustomization.yaml`
(tag mới) ngược lại repo. Trước khi làm tôi kiểm tra thực tế và gặp 3 điều làm A "nguyên bản"
không chạy được ở repo này:

1. **`main` có branch protection bắt buộc PR** (`gh api repos/<repo>/branches/main/protection`:
   `required_pull_request_reviews` có mặt; `enforce_admins: false` chỉ mở cửa cho *admin người*,
   không phải `github-actions[bot]`), và `default_workflow_permissions = read`. Bot không có cách
   hợp lệ để push thẳng vào `main`. Muốn push được phải hoặc (a) cấp PAT/GitHub App dài hạn — đi
   ngược nguyên tắc "không có credential tĩnh" (CLAUDE.md §10), hoặc (b) tháo branch protection.
2. **Phát hiện thay đổi bằng "diff của push" (`dorny/paths-filter` trên sự kiện push) không bền.**
   `concurrency` của GitHub chỉ giữ **1** run đang chờ: merge A, B, C liên tiếp thì run của B bị
   hủy — và B đã đổi service nào thì **không ai build**, vì run C chỉ so C với B.
3. **Cluster dev bị `destroy` mỗi tối** (CLAUDE.md §10). "Trạng thái đang chạy" nếu chỉ tồn tại
   trong cluster thì biến mất cùng cluster; sáng hôm sau không có gì để biết phải deploy lại cái gì.

## Quyết định

Tách "sự thật" thành **hai lớp**, mỗi lớp trả lời một câu hỏi khác nhau:

### Lớp 1 — *Desired state* là hàm số của một commit git

Tag image của service `S` tại commit `C` là **SHA của commit cuối cùng chạm vào thư mục của `S`**:

```bash
git log -1 --format=%H <C> -- apps/backend/customer-service     # → tag của customer-service
```

- Không phụ thuộc "event nào vừa xảy ra" → run bị hủy/chạy lại/chạy tay đều ra cùng một kết quả
  (idempotent). Giải quyết điểm 2 ở trên.
- Cùng source ⇒ cùng tag ⇒ **không build lại** (ECR tag `IMMUTABLE` cũng không cho ghi đè). Đây mới
  là "build once" thật: image của `customer-service` tại `v0.1.0` chính là image đã build khi
  commit cuối chạm `customer-service` được merge — không phải một bản build mới của tag.
- Ở mọi commit `C`, cả 7 service đều có tag xác định (commit cuối chạm nó) ⇒ **B-51 biến mất**:
  không còn khái niệm "service không có image ở SHA này".
- Cần `fetch-depth: 0` (clone nông làm `git log -1 -- path` trả về HEAD cho mọi service).
- `customer-service` phụ thuộc `bss-common-java` qua **artifact đã publish** (version ghim trong
  `pom.xml`, xem `publish-bss-common-java.yml`), không qua source → thư mục của nó đã đủ để xác
  định image; sửa thư viện chung mà chưa bump `pom.xml` không đổi image (đúng như build thật).

### Lớp 2 — *Last-known-good* là release manifest, sống ở nhánh `deploy-state`

Một JSON cho mỗi môi trường, mỗi release:

```
nhánh deploy-state (orphan, KHÔNG bảo vệ — bot ghi được bằng GITHUB_TOKEN)
├── dev.json  staging.json  prod.json     # bản đã deploy + smoke PASS gần nhất
└── releases/rc-v0.1.0.json  v0.1.0.json  # snapshot đóng băng của một release
```

```json
{ "schema": 1, "environment": "dev",
  "source": { "sha": "<commit trên main>", "ref": "refs/heads/main", "run_url": "…" },
  "deployed_at": "2026-09-25T10:00:00Z",
  "services": { "customer-service": "<sha>", "product-catalog": "<sha>", "…": "…" } }
```

- Manifest **chỉ được ghi SAU KHI** rollout xong + smoke test PASS ⇒ nó luôn là "bản tốt gần
  nhất". `git log deploy-state -- dev.json` = lịch sử deploy có thể audit (ai/khi nào/từ commit nào).
- **Rollback = áp lại manifest cũ cho cả 7 service**, không phải `kubectl rollout undo` từng
  deployment (cách cũ trong `cd-prod.yml` để lại hệ thống lẫn phiên bản: deployment nào lỗi thì
  undo, các deployment trước đó vẫn ở bản mới).
- Vì manifest nằm ngoài cluster, dựng lại dev sau khi destroy = deploy lại từ manifest. Giải
  quyết điểm 3.

### Cơ chế deploy — không sửa file trong git

Workflow sinh một `kustomization.yaml` tạm (`infrastructure/kubernetes/rendered/<env>/`, gitignored)
chỉ chứa `resources: [../../overlays/<env>]` + khối `images:` khớp theo **tên đầy đủ** đã được
overlay đổi (`<registry>/bss/<svc>`) với `newTag` lấy từ manifest. Overlay trong git giữ nguyên.

### Promotion

`aws ecr put-image` gắn thêm tag `rc-vX` / `vX` lên **cùng manifest digest** — không pull/push
layer nào. Deploy vẫn ghim bằng tag SHA bất biến; tag `rc-v*`/`v*` để con người đọc và để ECR
lifecycle **không xóa** image đã phát hành (rule ưu tiên 1 trong `modules/ecr`).

## Lựa chọn khác đã cân nhắc

| Phương án | Vì sao không chọn |
|---|---|
| **A nguyên bản** — bot commit overlay vào `main` | Bị branch protection chặn (điểm 1). Muốn chạy phải thêm PAT dài hạn hoặc bỏ bảo vệ. |
| **A + PR tự động** (bot mở PR bump tag rồi tự merge) | Cần PAT/App để PR kích hoạt được CI; mỗi deploy thêm một vòng PR + chờ CI; nhiễu lịch sử `main`. Lợi ích duy nhất (review) là vô nghĩa vì bot tự merge. |
| **B — ArgoCD** | Là đích đến hợp lý về lâu dài (không cần credential cluster trong CI, tự sửa drift) nhưng thêm một hệ thống phải cài/vận hành/bảo mật cho 7 service — CLAUDE.md §2: "không over-engineer". Xem lại khi >10 service hoặc cần tự heal drift. |
| **C — build cả 7 mỗi lần merge** | Đơn giản nhưng lãng phí, và **không** giải quyết rollback/nguồn sự thật (image giống hệt vẫn build lại, cluster vẫn không có "bản tốt gần nhất"). |
| **D — chỉ `kubectl set image` service đổi** | Cluster lệch khỏi git (drift), không có lịch sử, không dựng lại được sau destroy. |
| Lưu manifest ở SSM Parameter Store/S3 | Khả thi (có versioning), nhưng lịch sử/audit/diff bằng `git` quen thuộc hơn và không cần thêm quyền IAM/tài nguyên Terraform. Xem lại nếu cần ghi từ ngoài GitHub. |

## Hệ quả và đánh đổi

- ✅ Sửa B-50, B-51 tận gốc; chạy lại/chạy tay/run bị hủy đều an toàn; dựng lại dev sau nightly
  destroy chỉ là một lần deploy từ manifest.
- ✅ Không cần credential tĩnh, không sửa branch protection.
- ⚠️ **Nhánh `deploy-state` không được bảo vệ** ⇒ bất kỳ ai/workflow nào có `contents: write`
  đều có thể sửa "sự thật". Giảm thiểu: chỉ các job deploy có `contents: write` (mức workflow là
  `read`); ghi vào repo private của một người. Nếu nâng cấp: dùng repository ruleset chỉ cho
  `github-actions` được push nhánh này.
- ⚠️ Thay đổi phiên bản không còn là một PR để review — nhưng review đã diễn ra ở PR **code**
  (deploy = hệ quả của merge). Đây là điểm khác GitOps chuẩn; chấp nhận được với một người làm.
- ⚠️ `git log -1 -- path` chỉ đúng khi lịch sử `main` tuyến tính/đầy đủ → luôn `fetch-depth: 0`.
- ⚠️ ECR lifecycle ("giữ 20 image gắn tag") có thể xóa image mà manifest cũ tham chiếu. Đã xử lý
  cho image đã phát hành (tag `rc-v*`/`v*` được bảo vệ); rollback dev chỉ quay về được ≤ 20 lần
  build gần nhất của service — chấp nhận được.
- ⚠️ Dev bị destroy ban đêm: merge vào `main` lúc cluster không tồn tại **không** làm workflow đỏ —
  build + push image xong thì bỏ qua bước deploy (cảnh báo), lần sau chạy `workflow_dispatch`
  (hoặc merge tiếp) là đồng bộ về HEAD.

## Điều kiện xem lại

- >10 service, hoặc cần cluster tự sửa drift, hoặc nhiều người cùng đẩy lên prod → cân nhắc ArgoCD
  (phương án B): manifest `deploy-state` có thể trở thành nguồn cho ApplicationSet.
