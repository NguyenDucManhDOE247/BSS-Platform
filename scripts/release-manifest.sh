#!/usr/bin/env bash
# release-manifest.sh — "nguồn sự thật" về phiên bản đang chạy của CD (ADR-005; B-50, B-51).
#
# Hai khái niệm cần tách bạch (đọc ADR-005 trước):
#   • DESIRED  — hàm số của một commit git: tag image của service S tại commit C là SHA của
#                commit CUỐI CÙNG chạm vào thư mục của S. Không phụ thuộc "sự kiện nào vừa xảy ra".
#   • MANIFEST — bản ghi JSON "đã deploy + smoke PASS" của một môi trường, lưu ở nhánh
#                `deploy-state` (orphan, không bảo vệ). Đây là "last-known-good" để rollback.
#
# Cách dùng:  scripts/release-manifest.sh <lệnh> [tham số...]
#
#   Danh sách/đường dẫn
#     services                       JSON array 7 service (workflow dùng cho fromJson)
#     dir SERVICE                    apps/backend/<svc> hoặc apps/frontend/<svc>
#   Tính desired từ git (CẦN full history — từ chối clone nông)
#     desired [COMMIT]               JSON {service: sha} tại COMMIT (mặc định HEAD)
#     new ENV [COMMIT] [RUN_URL] [REF]   manifest hoàn chỉnh cho ENV từ desired(COMMIT)
#   Đọc/so sánh manifest (chỉ cần jq)
#     validate FILE                  đủ 7 service, tag là SHA 40 hex — sai thì exit 1
#     same OLD NEW                   exit 0 nếu phần `services` giống hệt (bỏ qua metadata)
#     diff OLD NEW                   in các service đổi (OLD có thể không tồn tại)
#     set-field FILE KEY VALUE       đặt trường chuỗi ở gốc (vd. release=rc-v0.1.0)
#     add-verified FILE ENV          thêm ENV vào `verified_in` (cổng promotion)
#   Triển khai (cần kubectl)
#     render FILE ENV REGISTRY       sinh kustomization tạm chồng `images:` lên overlays/ENV,
#                                    in ra thư mục vừa sinh — KHÔNG sửa file nào trong git
#     verify-cluster FILE REGISTRY   đọc `kubectl -n bss get deploy -o json` từ stdin, exit 1 nếu
#                                    image thực tế lệch manifest (drift)
#   ECR (cần aws cli)
#     ecr-missing FILE               JSON array các service mà image (tag trong FILE) chưa có
#     ecr-tag FILE TAG               `aws ecr put-image` gắn thêm TAG lên cùng manifest digest
#   Nhánh deploy-state (cần git + remote)
#     state-get PATH                 in nội dung PATH ở nhánh deploy-state; exit 3 nếu chưa có
#     state-put MSG PATH=FILE...     commit + push các file lên deploy-state (tự retry khi đua)
#
# Biến môi trường: STATE_BRANCH (deploy-state), STATE_REMOTE (origin), RM_RETRY_SLEEP (giây, để
# test đặt 0), RM_GIT_NAME/RM_GIT_EMAIL (danh tính commit của bot).
set -euo pipefail

SERVICES=(customer-service product-catalog order-management billing-service api-gateway web-portal admin-console)
FRONTENDS=(web-portal admin-console)
STATE_BRANCH="${STATE_BRANCH:-deploy-state}"
STATE_REMOTE="${STATE_REMOTE:-origin}"

die() { echo "release-manifest: $*" >&2; exit 1; }

need() { command -v "$1" >/dev/null 2>&1 || die "thiếu công cụ '$1' trong PATH"; }

service_dir() {
  local s="$1" f
  for f in "${FRONTENDS[@]}"; do
    if [ "$f" = "$s" ]; then echo "apps/frontend/$s"; return 0; fi
  done
  echo "apps/backend/$s"
}

services_json() {
  printf '%s\n' "${SERVICES[@]}" | jq -R . | jq -sc .
}

# ─── services / dir ────────────────────────────────────────────────────────
cmd_services() { services_json; }

cmd_dir() {
  local want="${1:?dir SERVICE}" s
  for s in "${SERVICES[@]}"; do
    if [ "$s" = "$want" ]; then service_dir "$s"; return 0; fi
  done
  die "service lạ: $want"
}

# ─── desired: hàm số của commit ────────────────────────────────────────────
cmd_desired() {
  local commit="${1:-HEAD}" s sha
  # Clone nông (mặc định của actions/checkout) làm `git log -1 -- path` trả về commit HEAD cho
  # MỌI service → tag giống hệt nhau → sai lặng lẽ. Từ chối thẳng thay vì cho ra kết quả sai.
  if [ "$(git rev-parse --is-shallow-repository)" = "true" ]; then
    die "repo là clone nông — chạy actions/checkout với fetch-depth: 0 (xem ADR-005)"
  fi
  git rev-parse --verify --quiet "$commit^{commit}" >/dev/null || die "commit không tồn tại: $commit"
  for s in "${SERVICES[@]}"; do
    sha="$(git log -1 --format=%H "$commit" -- "$(service_dir "$s")")"
    [ -n "$sha" ] || die "không có commit nào chạm $(service_dir "$s") tính đến $commit"
    printf '%s\t%s\n' "$s" "$sha"
  done | jq -Rn -S '[inputs | split("\t") | {key: .[0], value: .[1]}] | from_entries'
}

cmd_new() {
  local env="${1:?new ENV [COMMIT] [RUN_URL] [REF]}" commit="${2:-HEAD}" run_url="${3:-}" ref="${4:-}"
  local desired full
  desired="$(cmd_desired "$commit")"
  full="$(git rev-parse "$commit^{commit}")"
  jq -n -S \
    --arg env "$env" --arg sha "$full" --arg ref "$ref" --arg run "$run_url" \
    --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson services "$desired" \
    '{schema: 1, environment: $env, source: {sha: $sha, ref: $ref, run_url: $run}, deployed_at: $at, services: $services}'
}

# ─── validate / same / diff / set-field / add-verified ─────────────────────
cmd_validate() {
  local file="${1:?validate FILE}" want problems
  [ -f "$file" ] || die "không có file: $file"
  jq -e . "$file" >/dev/null 2>&1 || die "$file không phải JSON hợp lệ"
  want="$(services_json)"
  problems="$(jq -r --argjson want "$want" '
      [ (if .schema == 1 then empty else "schema phải là 1" end),
        (if (.environment | type) == "string" then empty else "thiếu environment" end),
        (($want - (.services // {} | keys))[] | "thiếu service: \(.)"),
        (((.services // {} | keys) - $want)[] | "service lạ: \(.)"),
        ((.services // {} | to_entries[] | select(.value | test("^[0-9a-f]{40}$") | not)
            | "tag không phải SHA 40 hex: \(.key)=\(.value)"))
      ] | .[]' "$file")"
  if [ -n "$problems" ]; then
    echo "$problems" | sed "s|^|release-manifest: $file: |" >&2
    exit 1
  fi
}

cmd_same() {
  local a="${1:?same OLD NEW}" b="${2:?same OLD NEW}"
  [ -f "$a" ] && [ -f "$b" ] || return 1
  [ "$(jq -cS .services "$a")" = "$(jq -cS .services "$b")" ]
}

cmd_diff() {
  local old="${1:-}" new="${2:?diff OLD NEW}" old_services='{}'
  if [ -n "$old" ] && [ -f "$old" ]; then old_services="$(jq -c .services "$old")"; fi
  jq -r --argjson o "$old_services" '
    .services | to_entries[]
    | select($o[.key] != .value)
    | ($o[.key] // "(mới)") as $prev
    | "\(.key): \($prev[0:12]) → \(.value[0:12])"' "$new"
}

cmd_set_field() {
  local file="${1:?set-field FILE KEY VALUE}" key="${2:?}" value="${3:?}" tmp
  tmp="$(mktemp)"
  jq -S --arg k "$key" --arg v "$value" '.[$k] = $v' "$file" > "$tmp" && mv "$tmp" "$file"
}

cmd_add_verified() {
  local file="${1:?add-verified FILE ENV}" env="${2:?}" tmp
  tmp="$(mktemp)"
  jq -S --arg e "$env" '.verified_in = (((.verified_in // []) + [$e]) | unique)' "$file" > "$tmp" && mv "$tmp" "$file"
}

# ─── render / verify-cluster ───────────────────────────────────────────────
cmd_render() {
  local file="${1:?render FILE ENV REGISTRY}" env="${2:?}" registry="${3:?}" root dir
  cmd_validate "$file"
  root="$(git rev-parse --show-toplevel)"
  [ -d "$root/infrastructure/kubernetes/overlays/$env" ] || die "không có overlay: $env"
  dir="$root/infrastructure/kubernetes/rendered/$env"
  mkdir -p "$dir"
  {
    echo "# SINH TỰ ĐỘNG bởi scripts/release-manifest.sh render — không sửa tay, không commit (gitignored)."
    echo "# Manifest nguồn: $(basename "$file") — source sha $(jq -r '.source.sha' "$file")"
    echo "apiVersion: kustomize.config.k8s.io/v1beta1"
    echo "kind: Kustomization"
    echo "resources:"
    echo "  - ../../overlays/$env"
    echo "# Khớp theo TÊN ĐẦY ĐỦ vì overlay đã đổi tên image (newName) trước bước này."
    echo "# newTag đặt trong ngoặc kép: một SHA toàn chữ số/'e' có thể bị YAML hiểu thành số."
    echo "images:"
    jq -r --arg reg "$registry" \
      '.services | to_entries[] | "  - name: \($reg)/bss/\(.key)\n    newTag: \"\(.value)\""' "$file"
  } > "$dir/kustomization.yaml"
  echo "$dir"
}

cmd_verify_cluster() {
  local file="${1:?verify-cluster FILE REGISTRY}" registry="${2:?}" drift
  cmd_validate "$file"
  drift="$(jq -r --arg reg "$registry" --slurpfile m "$file" '
      [ .items[] | {n: .metadata.name, i: .spec.template.spec.containers[0].image} ] as $have
      | $m[0].services | to_entries[]
      | . as $w
      | "\($reg)/bss/\($w.key):\($w.value)" as $want
      | ($have | map(select(.n == $w.key)) | (.[0].i // "MISSING")) as $got
      | select($got != $want)
      | "DRIFT \($w.key): cluster=\($got)  manifest=\($want)"')"
  if [ -n "$drift" ]; then
    echo "$drift" >&2
    die "cluster đang chạy image khác manifest"
  fi
  echo "verify-cluster: cả ${#SERVICES[@]} deployment khớp manifest."
}

# ─── ECR ───────────────────────────────────────────────────────────────────
cmd_ecr_missing() {
  local file="${1:?ecr-missing FILE}" s tag out missing=()
  cmd_validate "$file"
  need aws
  for s in "${SERVICES[@]}"; do
    tag="$(jq -r --arg s "$s" '.services[$s]' "$file")"
    if out="$(aws ecr describe-images --repository-name "bss/$s" --image-ids "imageTag=$tag" 2>&1)"; then
      :
    elif grep -q 'ImageNotFoundException' <<<"$out"; then
      missing+=("$s")
    else
      # AccessDenied/RepositoryNotFound/lỗi mạng KHÔNG được coi là "chưa có image" — nếu không,
      # một lỗi quyền sẽ khiến mọi service bị build lại rồi mới đổ vỡ ở bước push.
      die "aws ecr describe-images bss/$s lỗi: $out"
    fi
  done
  if [ "${#missing[@]}" -eq 0 ]; then echo '[]'; else printf '%s\n' "${missing[@]}" | jq -R . | jq -sc .; fi
}

cmd_ecr_tag() {
  local file="${1:?ecr-tag FILE TAG}" newtag="${2:?}" s sha src dst manifest media digest existing
  cmd_validate "$file"
  need aws
  for s in "${SERVICES[@]}"; do
    sha="$(jq -r --arg s "$s" '.services[$s]' "$file")"
    src="$(aws ecr batch-get-image --repository-name "bss/$s" --image-ids "imageTag=$sha" --output json)"
    manifest="$(jq -r '.images[0].imageManifest // empty' <<<"$src")"
    [ -n "$manifest" ] || die "bss/$s:$sha không tồn tại trong ECR — image này chưa được build bởi cd-dev?"
    media="$(jq -r '.images[0].imageManifestMediaType // empty' <<<"$src")"
    digest="$(jq -r '.images[0].imageId.imageDigest' <<<"$src")"
    dst="$(aws ecr batch-get-image --repository-name "bss/$s" --image-ids "imageTag=$newtag" --output json)"
    existing="$(jq -r '.images[0].imageId.imageDigest // empty' <<<"$dst")"
    if [ -n "$existing" ]; then
      # Tag đã tồn tại. Cùng digest = chạy lại lần nữa, vô hại. Khác digest = có người đã gắn tag
      # này vào image KHÁC — tag ECR là IMMUTABLE nên không được đè, dừng và báo.
      [ "$existing" = "$digest" ] || die "bss/$s:$newtag đã trỏ tới $existing, khác image $sha ($digest) — tag bất biến, không ghi đè"
      echo "ecr-tag: bss/$s:$newtag đã có (cùng digest) — bỏ qua"
      continue
    fi
    if [ -n "$media" ]; then
      aws ecr put-image --repository-name "bss/$s" --image-tag "$newtag" \
        --image-manifest "$manifest" --image-manifest-media-type "$media" >/dev/null
    else
      aws ecr put-image --repository-name "bss/$s" --image-tag "$newtag" --image-manifest "$manifest" >/dev/null
    fi
    echo "ecr-tag: bss/$s:$sha → :$newtag"
  done
}

# ─── nhánh deploy-state ────────────────────────────────────────────────────
state_exists() { git ls-remote --exit-code --heads "$STATE_REMOTE" "$STATE_BRANCH" >/dev/null 2>&1; }

cmd_state_get() {
  local path="${1:?state-get PATH}"
  state_exists || return 3
  git fetch -q "$STATE_REMOTE" "+refs/heads/$STATE_BRANCH:refs/remotes/$STATE_REMOTE/$STATE_BRANCH"
  git cat-file -e "refs/remotes/$STATE_REMOTE/$STATE_BRANCH:$path" 2>/dev/null || return 3
  git show "refs/remotes/$STATE_REMOTE/$STATE_BRANCH:$path"
}

STATE_README='# deploy-state

Nhánh này KHÔNG chứa mã nguồn. Nó lưu release manifest — bản ghi "môi trường nào đang chạy
image nào" — do CD ghi sau mỗi lần deploy + smoke test PASS (xem docs/adr/ADR-005).

    dev.json  staging.json  prod.json     bản đã deploy thành công gần nhất của từng môi trường
    releases/<tag>.json                   snapshot đóng băng của một release (rc-vX / vX)

Đừng sửa tay. Lịch sử deploy: `git log origin/deploy-state -- dev.json`.'

_state_cleanup() { [ -n "${1:-}" ] && { git worktree remove --force "$1/wt" >/dev/null 2>&1 || true; rm -rf "$1"; git worktree prune >/dev/null 2>&1 || true; }; }

cmd_state_put() {
  local msg="${1:?state-put MSG PATH=FILE...}"; shift
  [ "$#" -gt 0 ] || die "state-put cần ít nhất một PATH=FILE"
  local attempt=0 max=5 tmp pair path src
  local name="${RM_GIT_NAME:-github-actions[bot]}" email="${RM_GIT_EMAIL:-41898282+github-actions[bot]@users.noreply.github.com}"
  tmp="$(mktemp -d)"
  # Nội suy $tmp NGAY LÚC đặt trap (dấu nháy kép có chủ đích) — biến cục bộ sẽ không còn khi trap chạy.
  # shellcheck disable=SC2064
  trap "_state_cleanup '$tmp'" EXIT
  while :; do
    attempt=$((attempt + 1))
    if state_exists; then
      git fetch -q "$STATE_REMOTE" "+refs/heads/$STATE_BRANCH:refs/remotes/$STATE_REMOTE/$STATE_BRANCH"
      git -c core.autocrlf=false worktree add -q --detach "$tmp/wt" "refs/remotes/$STATE_REMOTE/$STATE_BRANCH"
    else
      # Lần đầu: tạo nhánh orphan (không dính lịch sử main) chỉ chứa README.
      git -c core.autocrlf=false worktree add -q --detach "$tmp/wt" HEAD
      git -C "$tmp/wt" checkout -q --orphan "$STATE_BRANCH"
      git -C "$tmp/wt" rm -rfq . >/dev/null 2>&1 || true
      printf '%s\n' "$STATE_README" > "$tmp/wt/README.md"
    fi
    for pair in "$@"; do
      path="${pair%%=*}"; src="${pair#*=}"
      [ -f "$src" ] || die "state-put: không có file nguồn $src"
      mkdir -p "$tmp/wt/$(dirname "$path")"
      cp "$src" "$tmp/wt/$path"
    done
    # core.autocrlf=false ở CẢ worktree add lẫn add: máy Windows (autocrlf=true) sẽ checkout file
    # thành CRLF rồi `add` lại thành khác blob LF đã commit → mỗi lần chạy đều thấy "có thay đổi".
    git -C "$tmp/wt" -c core.autocrlf=false add -A
    if git -C "$tmp/wt" diff --cached --quiet; then
      echo "state-put: không có gì thay đổi — bỏ qua commit."
      return 0
    fi
    # Đặt danh tính bằng biến môi trường (không phải `-c user.name`): GIT_AUTHOR_* của người gọi
    # sẽ thắng `-c`, khiến commit ghi tên người/CI khác thay vì bot — bản ghi audit phải nhất quán.
    GIT_AUTHOR_NAME="$name" GIT_AUTHOR_EMAIL="$email" GIT_COMMITTER_NAME="$name" GIT_COMMITTER_EMAIL="$email"       git -C "$tmp/wt" commit -q -m "$msg"
    if git -C "$tmp/wt" push -q "$STATE_REMOTE" "HEAD:refs/heads/$STATE_BRANCH"; then
      echo "state-put: đã push $STATE_BRANCH ($(git -C "$tmp/wt" rev-parse --short HEAD)) — $msg"
      return 0
    fi
    [ "$attempt" -lt "$max" ] || die "state-put: push thất bại sau $max lần thử"
    echo "state-put: push bị từ chối (đua với run khác?) — thử lại $attempt/$max" >&2
    git worktree remove --force "$tmp/wt" >/dev/null 2>&1 || rm -rf "$tmp/wt"
    git worktree prune >/dev/null 2>&1 || true
    sleep "${RM_RETRY_SLEEP:-$attempt}"
  done
}

# ─── dispatcher ────────────────────────────────────────────────────────────
usage() { sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; }

main() {
  local cmd="${1:-}"
  [ -n "$cmd" ] || { usage; exit 2; }
  shift
  case "$cmd" in
    services)       need jq; cmd_services "$@" ;;
    dir)            cmd_dir "$@" ;;
    desired)        need jq; need git; cmd_desired "$@" ;;
    new)            need jq; need git; cmd_new "$@" ;;
    validate)       need jq; cmd_validate "$@" ;;
    same)           need jq; cmd_same "$@" ;;
    diff)           need jq; cmd_diff "$@" ;;
    set-field)      need jq; cmd_set_field "$@" ;;
    add-verified)   need jq; cmd_add_verified "$@" ;;
    render)         need jq; need git; cmd_render "$@" ;;
    verify-cluster) need jq; cmd_verify_cluster "$@" ;;
    ecr-missing)    need jq; cmd_ecr_missing "$@" ;;
    ecr-tag)        need jq; cmd_ecr_tag "$@" ;;
    state-get)      need git; cmd_state_get "$@" ;;
    state-put)      need git; cmd_state_put "$@" ;;
    -h|--help|help) usage ;;
    *)              usage >&2; die "lệnh không có: $cmd" ;;
  esac
}

main "$@"
