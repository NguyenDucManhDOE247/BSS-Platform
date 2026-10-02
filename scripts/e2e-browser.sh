#!/usr/bin/env bash
# E2E trình duyệt thật (tests/e2e-browser, Playwright/Chromium) cho web-portal + admin-console:
#
#   ./scripts/e2e-browser.sh               # kind — http://bss.localhost (chạy trong WSL, nơi có kind)
#   ./scripts/e2e-browser.sh dev           # https://dev.bssplatform.dpdns.org   (cần aws + kubectl + docker)
#   ./scripts/e2e-browser.sh staging|prod  # https://staging.… / tên miền gốc
#
# Kết quả + ảnh chụp từng bước: tests/e2e-browser/test-results/ (journey/, admin/).
#
# Chạy trong Docker image Playwright ghim CÙNG version với tests/e2e-browser/package.json: có sẵn Chromium +
# thư viện hệ thống → không cần `sudo` cài gì.
#
# kind: `--network host` vì Chromium TỰ phân giải *.localhost về 127.0.0.1 (bỏ qua /etc/hosts) → container
# phải dùng chung mạng với nơi kind publish cổng 80; `--add-host` cho phần gọi API bằng Node.js (getaddrinfo
# không tự hiểu *.localhost — `ENOTFOUND` thật ở lần chạy đầu). Đăng nhập PKCE cần "secure context": chỉ
# *.localhost (kind) hoặc HTTPS (AWS) — ADR-008 QĐ 7.
#
# AWS: realm không có user mẫu → tạo 1 nhân viên (role admin) + 1 khách TẠM qua Admin API (port-forward,
# scripts/lib/keycloak.sh) rồi truyền vào test qua E2E_* env; test hành trình khách còn TỰ ĐĂNG KÝ 1 tài khoản
# qua trang Keycloak thật. Kết thúc (kể cả khi đỏ): xóa 2 user tạm + mọi user `e2e…` tạo trong lần chạy này.
# Dữ liệu nghiệp vụ test tạo ra (hồ sơ, gói đã ngừng bán, đơn, hóa đơn) ở lại DB — môi trường ephemeral.
set -euo pipefail
cd "$(dirname "$0")/.."

ENV="${1:-kind}"
PW_VERSION=$(sed -n 's/.*"@playwright\/test": *"\([0-9.]*\)".*/\1/p' tests/e2e-browser/package.json)
DOCKER_ARGS=()
E2E_ENV=()

if [ "$ENV" = "kind" ]; then
  BASE_URL="${BASE_URL:-http://bss.localhost}"
  DOCKER_ARGS=(--network host --add-host bss.localhost:127.0.0.1)
else
  # shellcheck source=lib/keycloak.sh
  . scripts/lib/keycloak.sh
  START_MS=""
  TEMP_IDS=()
  cleanup() {
    if [ -n "$START_MS" ]; then
      # User do test hành trình tự đăng ký (tên `e2e<timestamp>`) trong lần chạy này.
      for id in $(kc_admin GET "/users?search=e2e&max=200" \
                  | jqr --argjson t "$START_MS" '.[] | select(.createdTimestamp >= $t) | .id'); do
        kc_delete_user "$id"
      done
    fi
    for id in "${TEMP_IDS[@]+"${TEMP_IDS[@]}"}"; do kc_delete_user "$id"; done
    kc_disconnect
  }
  trap cleanup EXIT
  kc_connect "$ENV"
  kc_master_login
  START_MS="$(( $(date +%s) * 1000 - 5000 ))"
  RUN_ID="$(date +%s)"
  ADMIN_USER="e2e-staff-$RUN_ID"; ADMIN_PASS="$(kc_random_password)"
  CUST_USER="e2e-cust-$RUN_ID";   CUST_PASS="$(kc_random_password)"
  ADMIN_ID="$(kc_create_user "$ADMIN_USER" "$ADMIN_USER@example.com" "$ADMIN_PASS" false)"
  CUST_ID="$(kc_create_user "$CUST_USER" "$CUST_USER@example.com" "$CUST_PASS" false)"
  TEMP_IDS=("$ADMIN_ID" "$CUST_ID")
  kc_make_staff "$ADMIN_ID"
  HOST="$(kubectl --context "$KCTX" -n bss get ingress bss-ingress -o jsonpath='{.spec.rules[0].host}')"
  [ -n "$HOST" ] || { echo "✗ Ingress chưa có host — CD đã deploy $ENV chưa?" >&2; exit 1; }
  BASE_URL="https://$HOST"
  E2E_ENV=(-e "E2E_ADMIN_USER=$ADMIN_USER" -e "E2E_ADMIN_PASS=$ADMIN_PASS"
           -e "E2E_CUSTOMER_USER=$CUST_USER" -e "E2E_CUSTOMER_PASS=$CUST_PASS")
  echo "→ $ENV: nhân viên $ADMIN_USER + khách $CUST_USER (tạm, xóa khi xong) — $BASE_URL"
fi

WORK="$PWD/tests/e2e-browser"
USER_ARGS=(--user "$(id -u):$(id -g)")
case "$(uname -s)" in
  MINGW*|MSYS*)
    # Git Bash trên Windows (nơi có aws/kubectl): Docker Desktop cần đường dẫn Windows và KHÔNG được để MSYS
    # tự đổi `/work` thành `C:/Program Files/Git/work`; uid của Git Bash không có nghĩa trong container.
    WORK="$(cd tests/e2e-browser && pwd -W)"
    export MSYS_NO_PATHCONV=1
    USER_ARGS=()
    ;;
esac

docker run --rm ${DOCKER_ARGS[@]+"${DOCKER_ARGS[@]}"} \
  -e BASE_URL="$BASE_URL" ${E2E_ENV[@]+"${E2E_ENV[@]}"} \
  -v "$WORK:/work" -w /work \
  ${USER_ARGS[@]+"${USER_ARGS[@]}"} -e HOME=/tmp \
  "mcr.microsoft.com/playwright:v${PW_VERSION}-noble" \
  bash -c "npm ci --no-audit --no-fund --loglevel=error && npx playwright test"
