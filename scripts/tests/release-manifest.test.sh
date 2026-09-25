#!/usr/bin/env bash
# Test cho scripts/release-manifest.sh — không cần AWS, không cần cluster.
#
#   ./scripts/tests/release-manifest.test.sh
#
# Mỗi test dựng môi trường tạm: repo git giả (để thử `desired`), lệnh `aws` giả (để thử ecr-*),
# remote git giả (bare repo, để thử state-put/state-get + cơ chế retry khi đua nhau push).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RM="$HERE/../release-manifest.sh"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export RM_RETRY_SLEEP=0
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=t@t

pass=0; fail=0
ok()   { pass=$((pass + 1)); echo "  ✓ $1"; }
bad()  { fail=$((fail + 1)); echo "  ✗ $1"; [ -z "${2:-}" ] || echo "      $2"; }
eq()   { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "mong đợi [$3], nhận [$2]"; fi; }
fails() { # fails "mô tả" lệnh... — lệnh phải exit ≠ 0
  local d="$1"; shift
  if "$@" >/dev/null 2>&1; then bad "$d" "lệnh đáng lẽ phải thất bại"; else ok "$d"; fi
}
succeeds() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$d"; else bad "$d" "lệnh đáng lẽ phải thành công: $*"; fi; }
section() { echo; echo "── $1"; }

SVCS="customer-service product-catalog order-management billing-service api-gateway web-portal admin-console"

# Repo giả có đủ 7 thư mục service, để thử `desired`.
mkrepo() {
  local d="$1" s
  git init -q "$d"
  git -C "$d" config core.autocrlf false
  for s in $SVCS; do
    case "$s" in web-portal|admin-console) mkdir -p "$d/apps/frontend/$s" ;; *) mkdir -p "$d/apps/backend/$s" ;; esac
    echo v1 > "$d/$(cd "$d" && "$RM" dir "$s")/file"
  done
  ( cd "$d" && git add -A && git commit -q -m "c1: mọi service" )
}
touch_service() { # repo service msg
  ( cd "$1" && echo "$3" >> "$("$RM" dir "$2" 2>/dev/null || echo "$(cd "$REPO_ROOT" && "$RM" dir "$2")")/file" && git add -A && git commit -q -m "$3" )
}

# ═══════════════════════════════════════════════════════════════════════════
section "services / dir"
eq "services có đúng 7 phần tử" "$("$RM" services | jq 'length')" "7"
eq "dir backend"  "$("$RM" dir billing-service)" "apps/backend/billing-service"
eq "dir frontend" "$("$RM" dir web-portal)"      "apps/frontend/web-portal"
fails "dir từ chối service lạ" "$RM" dir khong-co

# ═══════════════════════════════════════════════════════════════════════════
section "desired — tag = commit cuối chạm thư mục service (ADR-005, lớp 1)"
R="$WORK/repo"; mkrepo "$R"
C1="$(git -C "$R" rev-parse HEAD)"
touch_service "$R" billing-service "c2: chỉ billing"; C2="$(git -C "$R" rev-parse HEAD)"
touch_service "$R" web-portal "c3: chỉ web-portal";   C3="$(git -C "$R" rev-parse HEAD)"
# một commit không chạm service nào (vd. sửa docs) không được làm đổi tag của ai
mkdir -p "$R/docs" && echo x > "$R/docs/a.md" && git -C "$R" add -A && git -C "$R" commit -q -m "c4: docs"
D="$(cd "$R" && "$RM" desired)"
eq "billing-service = c2"          "$(jq -r '.["billing-service"]' <<<"$D")"  "$C2"
eq "web-portal = c3"               "$(jq -r '.["web-portal"]' <<<"$D")"       "$C3"
eq "customer-service vẫn = c1"     "$(jq -r '.["customer-service"]' <<<"$D")" "$C1"
eq "commit docs không đổi tag nào" "$(jq -r '[.[]] | unique | length' <<<"$D")" "3"
# Tính chất then chốt cho promotion: desired tại một commit CŨ khác desired ở HEAD.
D_OLD="$(cd "$R" && "$RM" desired "$C2")"
eq "desired tại c2: web-portal chưa đổi (= c1)" "$(jq -r '.["web-portal"]' <<<"$D_OLD")" "$C1"
eq "desired tại c2: billing-service = c2"       "$(jq -r '.["billing-service"]' <<<"$D_OLD")" "$C2"
S="$WORK/shallow"; git -c core.autocrlf=false clone -q --depth 1 "file://$R" "$S"
fails "desired TỪ CHỐI clone nông" bash -c "cd '$S' && '$RM' desired"
fails "desired lỗi khi commit không tồn tại" bash -c "cd '$R' && '$RM' desired deadbeef"

# ═══════════════════════════════════════════════════════════════════════════
section "new / validate"
M="$WORK/m.json"; ( cd "$R" && "$RM" new dev HEAD "https://run/1" refs/heads/main ) > "$M"
succeeds "manifest do new sinh ra hợp lệ" "$RM" validate "$M"
eq "environment = dev"            "$(jq -r .environment "$M")"     "dev"
eq "source.sha là full SHA"       "$(jq -r .source.sha "$M")"      "$(git -C "$R" rev-parse HEAD)"
eq "khoá được sắp xếp (diff ổn định)" "$(jq -c 'keys' "$M")" '["deployed_at","environment","schema","services","source"]'
jq 'del(.services["api-gateway"])' "$M" > "$WORK/missing.json"
fails "validate bắt thiếu service" "$RM" validate "$WORK/missing.json"
jq '.services["api-gateway"]="dev"' "$M" > "$WORK/badtag.json"
fails "validate bắt tag không phải SHA (vd. 'dev')" "$RM" validate "$WORK/badtag.json"
jq '.services["thua"]="'"$C1"'"' "$M" > "$WORK/extra.json"
fails "validate bắt service lạ" "$RM" validate "$WORK/extra.json"
echo '{' > "$WORK/broken.json"
fails "validate bắt JSON hỏng" "$RM" validate "$WORK/broken.json"

# ═══════════════════════════════════════════════════════════════════════════
section "same / diff / set-field / add-verified"
M2="$WORK/m2.json"; jq --arg s "$C1" '.services["billing-service"]=$s | .deployed_at="khác"' "$M" > "$M2"
succeeds "same: bỏ qua metadata (deployed_at)" "$RM" same "$M" "$M"
fails    "same: phát hiện service đổi" "$RM" same "$M" "$M2"
fails    "same: file không tồn tại → không giống" "$RM" same "$WORK/khong-co.json" "$M"
eq "diff liệt kê đúng 1 dòng" "$("$RM" diff "$M2" "$M" | wc -l | tr -d ' ')" "1"
case "$("$RM" diff "$M2" "$M")" in billing-service:*) ok "diff nêu tên service đổi" ;; *) bad "diff nêu tên service đổi" ;; esac
eq "diff với file cũ chưa tồn tại → 7 dòng (mọi service là mới)" "$("$RM" diff "" "$M" | wc -l | tr -d ' ')" "7"
cp "$M" "$WORK/rel.json"
"$RM" set-field "$WORK/rel.json" release rc-v0.1.0
"$RM" add-verified "$WORK/rel.json" staging
"$RM" add-verified "$WORK/rel.json" staging
eq "set-field đặt release"          "$(jq -r .release "$WORK/rel.json")" "rc-v0.1.0"
eq "add-verified không thêm trùng"  "$(jq -c .verified_in "$WORK/rel.json")" '["staging"]'

# ═══════════════════════════════════════════════════════════════════════════
section "cổng promotion — on-main / gate-prod"
# repo giả R (đã có ở trên): nhánh chính hiện là HEAD; thêm một nhánh feature có commit riêng.
git -C "$R" branch -M main
git -C "$R" update-ref refs/remotes/origin/main "$(git -C "$R" rev-parse main)"
git -C "$R" switch -q -c feature
echo f >> "$R/apps/backend/api-gateway/file"; git -C "$R" add -A; git -C "$R" commit -q -m "feature-only"
FEAT="$(git -C "$R" rev-parse HEAD)"
succeeds "on-main: commit đã nằm trên main → đạt" bash -c "cd '$R' && '$RM' on-main '$C2'"
fails    "on-main: commit chỉ có ở nhánh feature → CHẶN (tag rc gắn nhầm)" bash -c "cd '$R' && '$RM' on-main '$FEAT'"
fails    "on-main: ref origin/main không tồn tại → báo lỗi thay vì cho qua" bash -c "cd '$R' && '$RM' on-main '$C2' origin/khong-co"
RC="$WORK/rc.json"; ( cd "$R" && "$RM" new staging "$C2" ) > "$RC"
fails    "gate-prod: rc CHƯA verified_in staging → chặn" "$RM" gate-prod "$RC" "$C2"
"$RM" add-verified "$RC" staging
succeeds "gate-prod: rc đã qua staging + đúng commit → đạt" "$RM" gate-prod "$RC" "$C2"
fails    "gate-prod: tag v trỏ commit khác commit rc đã test → chặn" "$RM" gate-prod "$RC" "$C3"
git -C "$R" switch -q main

# ═══════════════════════════════════════════════════════════════════════════
section "render — overlay thật của repo (cần kubectl)"
REG="132249065347.dkr.ecr.ap-southeast-1.amazonaws.com"
DIR="$(cd "$REPO_ROOT" && "$RM" render "$M" dev "$REG")"
eq "render in ra thư mục rendered/dev" "$(basename "$(dirname "$DIR")")/$(basename "$DIR")" "rendered/dev"
eq "render ghi đủ 7 khối images" "$(grep -c '^  - name: ' "$DIR/kustomization.yaml")" "7"
if command -v kubectl >/dev/null 2>&1; then
  OUT="$(kubectl kustomize "$DIR" 2>&1)"; rc=$?
  eq "kubectl kustomize build được overlay đã chồng images" "$rc" "0"
  bad_count=0
  for s in $SVCS; do
    tag="$(jq -r --arg s "$s" '.services[$s]' "$M")"
    grep -q "image: $REG/bss/$s:$tag\$" <<<"$OUT" || { bad_count=$((bad_count + 1)); echo "      thiếu image: $s:$tag"; }
  done
  eq "cả 7 image trong output = tag trong manifest (không còn ':dev')" "$bad_count" "0"
else
  echo "  - bỏ qua: không có kubectl trong PATH"
fi
rm -rf "$REPO_ROOT/infrastructure/kubernetes/rendered"

# ═══════════════════════════════════════════════════════════════════════════
section "verify-cluster — phát hiện drift"
mkdeploys() { # file [service=tag đè]
  local f="$1"; shift
  jq -n --arg reg "$REG" --slurpfile m "$M" '{items: [ $m[0].services | to_entries[] | {metadata:{name:.key}, spec:{template:{spec:{containers:[{image:"\($reg)/bss/\(.key):\(.value)"}]}}}} ]}' > "$f"
}
mkdeploys "$WORK/deploys.json"
succeeds "cluster khớp manifest" bash -c "'$RM' verify-cluster '$M' '$REG' < '$WORK/deploys.json'"
jq '.items[0].spec.template.spec.containers[0].image = "'"$REG"'/bss/customer-service:dev"' "$WORK/deploys.json" > "$WORK/drift.json"
fails "cluster chạy tag ':dev' → drift (chính là B-50)" bash -c "'$RM' verify-cluster '$M' '$REG' < '$WORK/drift.json'"
jq 'del(.items[2])' "$WORK/deploys.json" > "$WORK/gone.json"
fails "thiếu hẳn một deployment → drift" bash -c "'$RM' verify-cluster '$M' '$REG' < '$WORK/gone.json'"

# ═══════════════════════════════════════════════════════════════════════════
section "ecr-missing / ecr-tag — với lệnh aws giả"
FAKE="$WORK/fakeaws"; mkdir -p "$FAKE/bin" "$FAKE/ecr"
cat > "$FAKE/bin/aws" <<'AWS'
#!/usr/bin/env bash
# aws giả: chỉ hiểu `ecr describe-images|batch-get-image|put-image`. Kho ảnh giả là thư mục
# $FAKE_ECR/<repo với / → _>/<tag>, nội dung file = digest.
[ "$1" = ecr ] || { echo "fake aws: không hỗ trợ $*" >&2; exit 1; }
op="$2"; shift 2
repo=""; tag=""; newtag=""; manifest=""; media=""
while [ $# -gt 0 ]; do
  case "$1" in
    --repository-name) repo="$2"; shift 2 ;;
    --image-ids) tag="${2#imageTag=}"; shift 2 ;;
    --image-tag) newtag="$2"; shift 2 ;;
    --image-manifest) manifest="$2"; shift 2 ;;
    --image-manifest-media-type) media="$2"; shift 2 ;;
    *) shift ;;
  esac
done
dir="$FAKE_ECR/${repo//\//_}"
echo "$op $repo tag=$tag newtag=$newtag media=$media" >> "$FAKE_ECR/calls.log"
[ "${FAKE_ECR_DENY:-}" = 1 ] && { echo "An error occurred (AccessDeniedException) when calling the $op operation: denied" >&2; exit 254; }
case "$op" in
  describe-images)
    [ -f "$dir/$tag" ] || { echo "An error occurred (ImageNotFoundException) when calling the DescribeImages operation: not found" >&2; exit 254; }
    echo '{"imageDetails":[{}]}' ;;
  batch-get-image)
    if [ -f "$dir/$tag" ]; then
      printf '{"images":[{"imageId":{"imageDigest":"%s","imageTag":"%s"},"imageManifest":"{\\"fake\\":true}","imageManifestMediaType":"application/vnd.docker.distribution.manifest.v2+json"}],"failures":[]}\n' "$(cat "$dir/$tag")" "$tag"
    else
      echo '{"images":[],"failures":[{"failureCode":"ImageNotFound"}]}'
    fi ;;
  put-image)
    src_digest="$(cat "$dir/$(cat "$FAKE_ECR/last-src-tag")")"
    mkdir -p "$dir"; echo "$src_digest" > "$dir/$newtag"; echo '{"image":{}}' ;;
esac
AWS
chmod +x "$FAKE/bin/aws"
export FAKE_ECR="$FAKE/ecr"
# Kho giả: cả 7 service đều có image ĐÚNG tag trong manifest M, trừ web-portal.
for s in $SVCS; do
  [ "$s" = web-portal ] && continue
  mkdir -p "$FAKE_ECR/bss_$s"; echo "sha256:digest-$s" > "$FAKE_ECR/bss_$s/$(jq -r --arg s "$s" '.services[$s]' "$M")"
done
export PATH="$FAKE/bin:$PATH"
eq "ecr-missing chỉ báo web-portal" "$("$RM" ecr-missing "$M")" '["web-portal"]'
FAKE_ECR_DENY=1 fails "ecr-missing KHÔNG coi AccessDenied là 'chưa có image'" "$RM" ecr-missing "$M"
mkdir -p "$FAKE_ECR/bss_web-portal"; echo "sha256:digest-web-portal" > "$FAKE_ECR/bss_web-portal/$(jq -r '.services["web-portal"]' "$M")"
eq "đủ image → ecr-missing = []" "$("$RM" ecr-missing "$M")" '[]'

# put-image của aws giả cần biết tag nguồn — shim nhỏ ghi lại mỗi lần batch-get-image nguồn.
mv "$FAKE/bin/aws" "$FAKE/bin/aws.real"
cat > "$FAKE/bin/aws" <<'SHIM'
#!/usr/bin/env bash
if [ "$2" = batch-get-image ]; then
  for a in "$@"; do case "$a" in imageTag=*) t="${a#imageTag=}"; [ ${#t} -eq 40 ] && echo "$t" > "$FAKE_ECR/last-src-tag" ;; esac; done
fi
exec "$(dirname "$0")/aws.real" "$@"
SHIM
chmod +x "$FAKE/bin/aws"
: > "$FAKE_ECR/calls.log"
succeeds "ecr-tag gắn rc-v0.1.0 lên cả 7 image" "$RM" ecr-tag "$M" rc-v0.1.0
eq "sau ecr-tag: 7 lệnh put-image" "$(grep -c '^put-image' "$FAKE_ECR/calls.log")" "7"
eq "put-image kèm media type (image OCI/manifest list không bị hỏng)" "$(grep '^put-image' "$FAKE_ECR/calls.log" | grep -c 'media=application/vnd.docker.distribution.manifest.v2+json')" "7"
: > "$FAKE_ECR/calls.log"
succeeds "ecr-tag chạy lại lần 2 (idempotent)" "$RM" ecr-tag "$M" rc-v0.1.0
eq "lần 2 không gọi put-image nào" "$(grep -c '^put-image' "$FAKE_ECR/calls.log")" "0"
echo "sha256:someone-else" > "$FAKE_ECR/bss_api-gateway/rc-v0.2.0"
fails "ecr-tag từ chối đè tag đã trỏ image khác (ECR IMMUTABLE)" "$RM" ecr-tag "$M" rc-v0.2.0
rm "$FAKE_ECR/bss_api-gateway/$(jq -r '.services["api-gateway"]' "$M")"
fails "ecr-tag báo lỗi rõ khi image nguồn chưa được build" "$RM" ecr-tag "$M" rc-v0.3.0

# ═══════════════════════════════════════════════════════════════════════════
section "state-put / state-get — nhánh deploy-state trên remote giả"
BARE="$WORK/origin.git"; git init -q --bare "$BARE"
W1="$WORK/w1"; git -c core.autocrlf=false clone -q "$BARE" "$W1" 2>/dev/null
( cd "$W1" && echo hi > a && git add a && git commit -q -m init && git push -q origin HEAD:main ) 2>/dev/null
rc=0; ( cd "$W1" && "$RM" state-get dev.json >/dev/null 2>&1 ) || rc=$?
eq "state-get: chưa có nhánh → exit 3" "$rc" "3"
echo '{"v":1}' > "$WORK/dev1.json"
( cd "$W1" && "$RM" state-put "deploy(dev): lần 1" "dev.json=$WORK/dev1.json" ) >/dev/null
eq "state-get đọc lại đúng nội dung vừa put" "$(cd "$W1" && "$RM" state-get dev.json | jq -c .)" '{"v":1}'
eq "nhánh deploy-state có README + dev.json" "$(git -C "$BARE" ls-tree -r --name-only deploy-state | sort | tr '\n' ' ')" "README.md dev.json "
eq "nhánh deploy-state là orphan (không dính lịch sử main)" "$(git -C "$BARE" rev-list --count deploy-state)" "1"
rc=0; ( cd "$W1" && "$RM" state-get prod.json >/dev/null 2>&1 ) || rc=$?
eq "state-get: có nhánh nhưng thiếu file → exit 3" "$rc" "3"
out="$( cd "$W1" && "$RM" state-put "deploy(dev): lần 1 lặp lại" "dev.json=$WORK/dev1.json" )"
case "$out" in *"không có gì thay đổi"*) ok "state-put không commit khi nội dung y hệt" ;; *) bad "state-put không commit khi nội dung y hệt" "$out" ;; esac
echo '{"v":2}' > "$WORK/dev2.json"
( cd "$W1" && "$RM" state-put "deploy(dev): lần 2" "dev.json=$WORK/dev2.json" "releases/rc-v1.json=$WORK/dev2.json" ) >/dev/null
eq "put nhiều file, có thư mục con" "$(git -C "$BARE" ls-tree -r --name-only deploy-state | sort | tr '\n' ' ')" "README.md dev.json releases/rc-v1.json "
eq "lịch sử = commit khởi tạo + lần put có thay đổi thứ 2 = 2 commit" "$(git -C "$BARE" rev-list --count deploy-state)" "2"
eq "tác giả commit là bot (kể cả khi người gọi đặt GIT_AUTHOR_NAME khác)" "$(git -C "$BARE" log -1 --format=%an deploy-state)" "github-actions[bot]"

# Đua nhau push: hook pre-receive từ chối lần đầu (giống khi run khác vừa push xen giữa).
mkdir -p "$BARE/hooks"
cat > "$BARE/hooks/pre-receive" <<HOOK
#!/usr/bin/env bash
c="$WORK/rejected-once"
[ -f "\$c" ] && exit 0
touch "\$c"; echo "giả lập: bị đua, từ chối lần đầu" >&2; exit 1
HOOK
chmod +x "$BARE/hooks/pre-receive"
echo '{"v":3}' > "$WORK/dev3.json"
( cd "$W1" && "$RM" state-put "deploy(dev): lần 3 (đua)" "dev.json=$WORK/dev3.json" ) >/dev/null 2>&1
eq "state-put tự retry và cuối cùng thành công" "$(cd "$W1" && "$RM" state-get dev.json | jq -c .)" '{"v":3}'
rm -f "$BARE/hooks/pre-receive"

# ═══════════════════════════════════════════════════════════════════════════
echo
echo "════════ kết quả: $pass đạt, $fail hỏng ════════"
[ "$fail" -eq 0 ]
