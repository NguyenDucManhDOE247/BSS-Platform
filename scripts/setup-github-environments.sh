#!/usr/bin/env bash
# Tạo 3 GitHub Environment (dev / staging / production) + các variable mà workflow CD cần
# (Giai đoạn 6, B-39). Idempotent — chạy lại bao nhiêu lần cũng được.
#
#   ./scripts/setup-github-environments.sh            # DRY-RUN: chỉ in ra việc sẽ làm (mặc định)
#   ./scripts/setup-github-environments.sh --apply    # thật sự gọi GitHub API
#
# Vì sao cần: trust policy của mỗi role deployer (environments/shared) khớp `sub` dạng
# `repo:<owner>/<repo>:environment:<tên>` — job nào KHÔNG khai báo `environment:` hoặc chạy ở
# Environment khác sẽ không lấy được role. Bản thân Environment là nơi đặt luật bảo vệ:
#
#   Environment   Ai được deploy vào              Duyệt tay?   Role AWS (variable AWS_ROLE_ARN)
#   dev           nhánh main                      không        bss-github-deployer-dev
#   staging       tag rc-v*                       không        bss-github-deployer-staging
#   production    tag v*                          CÓ (bạn)     bss-github-deployer-prod
#
# Yêu cầu: gh (đã `gh auth login`, scope repo), jq. Repo phải hỗ trợ Environment protection rules
# (repo public, hoặc gói trả phí cho repo private).
#
# Biến môi trường (đều tuỳ chọn):
#   AWS_ACCOUNT_ID    bỏ qua bước hỏi `aws sts get-caller-identity`
#   REVIEWER_LOGIN    GitHub login của người duyệt production (mặc định: người đang đăng nhập gh)
#   PREVENT_SELF_REVIEW=true   người bấm tag không được tự duyệt (cần ≥ 2 người — làm một mình thì để false)
#
# Role ARN suy ra từ tên (bss-github-deployer-<env> — cố định trong environments/shared) nên KHÔNG cần
# đọc Terraform state; role phải tồn tại khi workflow chạy, không phải lúc chạy script này.
set -euo pipefail

APPLY=0
for a in "$@"; do
  case "$a" in
    --apply) APPLY=1 ;;
    -h|--help) sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "tham số lạ: $a (chỉ có --apply)" >&2; exit 2 ;;
  esac
done

command -v gh >/dev/null || { echo "thiếu gh"; exit 1; }
command -v jq >/dev/null || { echo "thiếu jq"; exit 1; }

REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner)"
ACCOUNT="${AWS_ACCOUNT_ID:-$(aws sts get-caller-identity --query Account --output text)}"
REGISTRY="$ACCOUNT.dkr.ecr.ap-southeast-1.amazonaws.com"
REVIEWER_LOGIN="${REVIEWER_LOGIN:-$(gh api user --jq .login)}"
REVIEWER_ID="$(gh api "users/$REVIEWER_LOGIN" --jq .id)"
PREVENT_SELF_REVIEW="${PREVENT_SELF_REVIEW:-false}"

[ "$APPLY" -eq 1 ] && echo "== APPLY trên $REPO (account $ACCOUNT) ==" || echo "== DRY-RUN trên $REPO (account $ACCOUNT) — thêm --apply để thực hiện =="

# do MÔ_TẢ LỆNH... — dry-run chỉ in, apply mới chạy
do_it() {
  local desc="$1"; shift
  if [ "$APPLY" -eq 1 ]; then
    echo "→ $desc"
    "$@"
  else
    echo "+ $desc"
    echo "    $*"
  fi
}

# put_environment TÊN JSON_BODY
put_environment() {
  local name="$1" body="$2"
  if [ "$APPLY" -eq 1 ]; then
    echo "→ environment '$name'"
    gh api -X PUT "repos/$REPO/environments/$name" --input - <<<"$body" >/dev/null
  else
    echo "+ environment '$name'  (PUT repos/$REPO/environments/$name)"
    echo "    body: $(jq -c . <<<"$body")"
  fi
}

# ensure_policy TÊN_ENV PATTERN branch|tag — chỉ tạo nếu chưa có (POST trùng sẽ lỗi 422)
ensure_policy() {
  local env="$1" pattern="$2" type="$3" existing=""
  if [ "$APPLY" -eq 1 ]; then
    existing="$(gh api "repos/$REPO/environments/$env/deployment-branch-policies" --jq '.branch_policies[] | select(.name=="'"$pattern"'") | .name' 2>/dev/null || true)"
    if [ -n "$existing" ]; then echo "  ✓ policy $type '$pattern' đã có ở '$env'"; return 0; fi
    echo "→ policy: '$env' chỉ nhận $type '$pattern'"
    gh api -X POST "repos/$REPO/environments/$env/deployment-branch-policies" -f name="$pattern" -f type="$type" >/dev/null
  else
    echo "+ policy: '$env' chỉ nhận $type '$pattern'"
  fi
}

CUSTOM_POLICY='{"protected_branches": false, "custom_branch_policies": true}'

put_environment dev     "$(jq -n --argjson p "$CUSTOM_POLICY" '{deployment_branch_policy: $p}')"
put_environment staging "$(jq -n --argjson p "$CUSTOM_POLICY" '{deployment_branch_policy: $p}')"
put_environment production "$(jq -n --argjson p "$CUSTOM_POLICY" --argjson id "$REVIEWER_ID" --argjson psr "$PREVENT_SELF_REVIEW" \
  '{deployment_branch_policy: $p, reviewers: [{type: "User", id: $id}], prevent_self_review: $psr}')"

ensure_policy dev        main   branch
ensure_policy staging    'rc-v*' tag
ensure_policy production 'v*'    tag

do_it "repository variable ECR_REGISTRY" gh variable set ECR_REGISTRY --body "$REGISTRY"
do_it "dev.AWS_ROLE_ARN"        gh variable set AWS_ROLE_ARN --env dev        --body "arn:aws:iam::$ACCOUNT:role/bss-github-deployer-dev"
do_it "staging.AWS_ROLE_ARN"    gh variable set AWS_ROLE_ARN --env staging    --body "arn:aws:iam::$ACCOUNT:role/bss-github-deployer-staging"
do_it "production.AWS_ROLE_ARN" gh variable set AWS_ROLE_ARN --env production --body "arn:aws:iam::$ACCOUNT:role/bss-github-deployer-prod"

echo ""
echo "Người duyệt production: $REVIEWER_LOGIN (prevent_self_review=$PREVENT_SELF_REVIEW)"
echo "Kiểm tra:  gh api repos/$REPO/environments --jq '.environments[].name'"
echo "           gh variable list --env production"
