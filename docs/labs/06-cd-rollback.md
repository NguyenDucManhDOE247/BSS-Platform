# Lab 06 — Cố tình deploy bản lỗi, xem CD tự quay về

**Mục tiêu (Giai đoạn 6, việc 6):** tận mắt thấy hai cách khác nhau mà một bản deploy có thể hỏng, và
thấy `cd-dev` tự rollback về manifest last-known-good trong cả hai — cùng dấu vết trong log và trong
nhánh `deploy-state`.

**Học được gì:**
- Vì sao `maxUnavailable: 0` giữ dev **không downtime** dù bản mới không bao giờ lên.
- Vì sao `rollout status` **không đủ**: một bản "Pod Ready" vẫn có thể hỏng nghiệp vụ → cần smoke test thật (B-52).
- Vì sao rollback là "áp lại cả manifest cũ" chứ không phải `rollout undo` từng deployment (ADR-005).

⚠️ Lab **merge code lỗi vào `main`** (repo của bạn, môi trường dev) — làm theo đúng phần "Dọn dẹp" ở
cuối. CI của 2 PR lab vẫn **xanh** (lỗi chỉ lộ ở runtime trên cluster): đó chính là lý do phải có lớp
bảo vệ sau CI.

## 0. Điều kiện

1. Dev đang chạy (đã `terraform apply`, `platform-install.sh`, `db-bootstrap`).
2. **Đã có ít nhất một lần CD dev PASS** — tức `dev.json` đã tồn tại. Kiểm:
   ```bash
   git fetch origin deploy-state && git show origin/deploy-state:dev.json | jq .source.sha
   ```
   Nếu lệnh báo không có file/nhánh → chạy `Actions → CD — dev → Run workflow` và đợi xanh trước (lần
   deploy đầu tiên **không thể** rollback — chưa có gì để quay về).
3. Lưu trạng thái tốt để so sánh sau:
   ```bash
   git show origin/deploy-state:dev.json | jq -c .services > /tmp/good.json
   ```

Mở 2 cửa sổ quan sát: `kubectl -n bss get pods -w` và `gh run watch` (chọn run `CD — dev`).

## Ca A — Pod không bao giờ Ready (rollout timeout)

1. `git switch -c lab/cd-rollback-a main`
2. Phá `product-catalog`: ứng dụng nghe cổng khác trong khi probe/Service vẫn trỏ 8080.
   Trong `apps/backend/product-catalog/src/main/resources/application.yml`, dưới `server:`, đổi
   `port: 8080` → `port: 9090`.
3. `git commit -am "lab: product-catalog nghe sai cổng"`, push, mở PR, chờ CI xanh, **Squash and merge**.
4. Quan sát:
   - `kubectl -n bss get pods -w`: Pod `product-catalog` mới ở `0/1`, restart lặp lại vì startupProbe
     hỏng; **Pod cũ vẫn `1/1`** (maxUnavailable: 0) — dev không hề sập.
   - Sau ~5 phút bước **Chờ rollout cả 7 deployment** báo `timed out waiting for the condition`.
   - Bước `Chẩn đoán` rồi **`Rollback về manifest last-known-good`** chạy; log có
     `::warning::Deploy hỏng — rollback về manifest cũ (source …)` và cuối cùng `Smoke test passed`.
   - Run **đỏ** (đúng thiết kế) nhưng `kubectl -n bss get deploy product-catalog -o wide` đã chạy lại **image cũ**.
5. Kiểm chứng "manifest không bị ghi khi hỏng":
   ```bash
   git fetch origin deploy-state
   git show origin/deploy-state:dev.json | jq -c .services | diff - /tmp/good.json && echo "dev.json KHÔNG đổi ✓"
   ```

## Ca B — Pod Ready nhưng nghiệp vụ hỏng (smoke test bắt được)

1. Sau khi Ca A đã được revert và dev xanh lại: `git switch -c lab/cd-rollback-b main`
2. Phá đường đi gateway → product. Trong `apps/backend/api-gateway/src/main/resources/application.yml`,
   route `id: product`, đổi `uri: http://product-catalog.bss.svc.cluster.local` thành
   `uri: http://product-catalog.bss.svc.cluster.local:9999`. api-gateway vẫn khỏe (`/actuator/health`
   UP) nhưng mọi lời gọi tới product đều lỗi.
3. Commit, PR, merge như Ca A.
4. Quan sát:
   - `rollout status` **PASS** (Pod Ready!) — nếu CD dừng ở đây thì bản hỏng đã "thành công".
   - Bước **Smoke test** thử lại ~5 phút (retry, vì có thể là ALB chưa đăng ký target) rồi
     `✗ FAILED … productOffering` → exit 1 → rollback.
   - Với smoke kiểu cũ (`|| true`) run này sẽ **xanh** và để dev hỏng — thử tưởng tượng ở prod.
5. Kiểm `dev.json` không đổi như Ca A.

## Dọn dẹp

`main` vẫn chứa code lỗi dù cluster đã tự hồi phục, nên phải revert (đảo thứ tự: Ca B rồi Ca A):

```bash
git switch main && git pull
git switch -c lab/revert main
git revert --no-edit <sha-merge-ca-B>
git revert --no-edit <sha-merge-ca-A>
git push -u origin lab/revert     # mở PR, merge → CD dev chạy lại và phải PASS
```

## Câu hỏi tự kiểm tra

1. Ở Ca A, vì sao người dùng không thấy sự cố dù Pod mới crash suốt 5 phút? (gợi ý: `maxUnavailable`, readinessProbe)
2. Ở Ca B, `rollout status` PASS nhưng smoke FAIL. Kể hai sự cố thật khác cũng thuộc loại này.
3. Vì sao manifest chỉ được ghi **sau** smoke PASS? Điều gì hỏng nếu ghi trước?
4. Nếu chạy lab này trên cluster dev **mới dựng** (chưa có `dev.json`), điều gì xảy ra ở bước rollback?
5. Rollback kiểu cũ (`rollout undo` từng deployment) sẽ để lại gì nếu chỉ deployment thứ 4/7 hỏng?
