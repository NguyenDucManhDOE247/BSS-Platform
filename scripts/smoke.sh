#!/usr/bin/env bash
# Smoke test một môi trường qua ALB — và PHẢI thất bại (exit 1) khi có gì hỏng, vì CD dùng exit
# code này để quyết định rollback tự động (B-52; ADR-005).
#
# Usage:
#   ./scripts/smoke.sh dev                                    # tra ALB của bss-dev-eks qua kubectl
#   SMOKE_BASE_URL=http://localhost:8080 ./scripts/smoke.sh   # trỏ thẳng vào một gateway (local/kind/test)
#
# Biến môi trường:
#   SMOKE_TIMEOUT_SECONDS   tổng thời gian chờ MỖI phase (đợi ALB có hostname; mỗi endpoint đạt) — mặc định 300
#   SMOKE_INTERVAL_SECONDS  nghỉ giữa các lần thử — mặc định 10
#   SMOKE_TOKEN             (chỉ chế độ SMOKE_BASE_URL) access token của 1 user role `customer` — có thì
#                           chạy thêm các kiểm tra cần đăng nhập. Chế độ AWS tự lấy token (xem dưới).
#
# Vì sao có retry (Giai đoạn 6): ngay sau `rollout status` xong, ALB vẫn cần ~30–60 giây để đăng ký
# Pod mới vào target group (và vài phút cho ALB mới tạo). Smoke chạy đúng lúc đó mà không retry sẽ
# 502/503 "giả" và kích hoạt rollback oan. Retry chỉ che độ trễ hạ tầng — nếu endpoint thật sự hỏng,
# hết thời gian chờ vẫn exit 1.
#
# Giai đoạn 9 việc 7 — auth BẬT trên AWS (ADR-008). Bản trước gọi `GET /customer` không token và mong
# 200 → giờ phải 401. Smoke kiểm cả 2 chiều của auth:
#   • không token → 401 (B-18 thật sự đóng — nếu ai lỡ tắt auth, smoke ĐỎ và CD rollback);
#   • token user `customer` → vào được `/customer/me` (200 có hồ sơ / 404 chưa có — cả 2 đều nghĩa là
#     token được customer-service chấp nhận), nhưng API quản trị `GET /customer` → 403 (phân quyền role).
# Token (chế độ AWS): Keycloak KHÔNG mở ra ALB khi chưa có HTTPS (ADR-008 quyết định 8), nên smoke đi
# vào Keycloak bằng `kubectl port-forward` (qua API server, có TLS); mật khẩu admin master realm đọc từ
# K8s Secret `keycloak-admin` cũng qua kubectl — không mật khẩu nào đi qua HTTP ngoài internet. Smoke
# dùng user riêng `smoke-bot` (role customer mặc định, không có hồ sơ/dữ liệu), đặt lại mật khẩu ngẫu
# nhiên mỗi lần chạy. Token của nó (hết hạn sau vài phút, không có quyền quản trị) mới đi qua HTTP tới
# ALB — rủi ro chấp nhận được cho tới khi có HTTPS.
#
# Lịch sử (B-52): bản đầu có 2 lỗi khiến script KHÔNG BAO GIỜ fail — (1) `curl | jq || echo` nuốt
# exit code; (2) gọi `/api/actuator/health` mà gateway không hề có route. Bản Giai đoạn 5 sửa cả
# hai; bản Giai đoạn 6 thêm: retry, và kiểm NỘI DUNG (200 + `[]` cũng là hỏng — seed data không có).
set -euo pipefail

ENV="${1:-dev}"
REGION="${AWS_REGION:-ap-southeast-1}"
TIMEOUT="${SMOKE_TIMEOUT_SECONDS:-300}"
INTERVAL="${SMOKE_INTERVAL_SECONDS:-10}"
TOKEN="${SMOKE_TOKEN:-}"

PF_PID=""
cleanup() { [ -z "$PF_PID" ] || kill "$PF_PID" 2>/dev/null || true; }
trap cleanup EXIT

# Lấy token user `smoke-bot` qua Keycloak trong cluster (chế độ AWS). In token ra stdout.
aws_smoke_token() {
  # SMOKE_KC_PORT: cổng local cho port-forward. 18080 chạy được trên runner Linux, nhưng trên Windows nó nằm
  # trong dải cổng Hyper-V/WSL giữ riêng (18028–18127 trên máy dev, 2026-10-01: "bind: forbidden by its access
  # permissions") → smoke chạy tay từ Windows luôn báo "Keycloak chưa sẵn sàng" dù Keycloak khỏe. Xem dải bị
  # giữ: `netsh interface ipv4 show excludedportrange protocol=tcp`.
  local kc_port="${SMOKE_KC_PORT:-18080}" admin_user admin_pass master uid pass tok body
  kubectl -n bss rollout status deployment/keycloak --timeout="${TIMEOUT}s" >&2
  kubectl -n bss port-forward svc/keycloak "$kc_port:8080" >/dev/null 2>&1 &
  PF_PID=$!
  local kc="http://127.0.0.1:$kc_port/auth"
  for _ in $(seq 1 30); do curl -fsS -o /dev/null "$kc/realms/bss" 2>/dev/null && break; sleep 1; done
  curl -fsS -o /dev/null "$kc/realms/bss" || { echo "✗ port-forward tới Keycloak không dùng được" >&2; return 1; }

  admin_user="$(kubectl -n bss get secret keycloak-admin -o jsonpath='{.data.username}' | base64 -d)"
  admin_pass="$(kubectl -n bss get secret keycloak-admin -o jsonpath='{.data.password}' | base64 -d)"
  master="$(curl -fsS "$kc/realms/master/protocol/openid-connect/token" -d grant_type=password -d client_id=admin-cli \
    --data-urlencode "username=$admin_user" --data-urlencode "password=$admin_pass" | jq -r '.access_token')"
  [ -n "$master" ] && [ "$master" != "null" ] || { echo "✗ không đăng nhập được Keycloak master" >&2; return 1; }

  uid="$(curl -fsS -H "Authorization: Bearer $master" "$kc/admin/realms/bss/users?username=smoke-bot&exact=true" | jq -r '.[0].id // empty')"
  if [ -z "$uid" ]; then
    curl -fsS -X POST -H "Authorization: Bearer $master" -H 'Content-Type: application/json' "$kc/admin/realms/bss/users" \
      -d '{"username":"smoke-bot","email":"smoke-bot@example.invalid","firstName":"Smoke","lastName":"Bot","enabled":true,"emailVerified":true}' >/dev/null
    uid="$(curl -fsS -H "Authorization: Bearer $master" "$kc/admin/realms/bss/users?username=smoke-bot&exact=true" | jq -r '.[0].id')"
  fi
  pass="$(openssl rand -base64 18 | tr -d '/+=')"
  body="$(jq -n --arg p "$pass" '{type:"password", value:$p, temporary:false}')"
  curl -fsS -X PUT -H "Authorization: Bearer $master" -H 'Content-Type: application/json' \
    "$kc/admin/realms/bss/users/$uid/reset-password" -d "$body" >/dev/null
  tok="$(curl -fsS "$kc/realms/bss/protocol/openid-connect/token" -d grant_type=password -d client_id=api-gateway \
    -d username=smoke-bot --data-urlencode "password=$pass" | jq -r '.access_token')"
  [ -n "$tok" ] && [ "$tok" != "null" ] || { echo "✗ không lấy được token cho smoke-bot" >&2; return 1; }
  echo "$tok"
}

if [ -n "${SMOKE_BASE_URL:-}" ]; then
  BASE="${SMOKE_BASE_URL%/}"
else
  aws eks update-kubeconfig --region "$REGION" --name "bss-$ENV-eks" >/dev/null
  HOST=""
  deadline=$((SECONDS + TIMEOUT))
  while :; do
    HOST="$(kubectl -n bss get ingress bss-ingress -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)"
    [ -z "$HOST" ] || break
    if [ "$SECONDS" -ge "$deadline" ]; then
      echo "✗ Hết ${TIMEOUT}s mà Ingress vẫn chưa có hostname — ALB chưa được tạo (xem: kubectl -n bss describe ingress bss-ingress)."
      exit 1
    fi
    echo "… chờ ALB có hostname"
    sleep "$INTERVAL"
  done
  BASE="http://$HOST"
  echo "→ Lấy token user smoke-bot qua Keycloak trong cluster (port-forward)…"
  TOKEN="$(aws_smoke_token)" || { echo "✗ Smoke test FAILED — không lấy được token (Keycloak chưa sẵn sàng?)."; exit 1; }
fi

echo "→ Smoke testing $BASE"

fail=0

# check LABEL PATH WANT JQ_FILTER MÔ_TẢ [curl args…] — đạt khi HTTP status khớp regex WANT VÀ
# `jq -e FILTER` đúng trên body (FILTER = "-": không xét body — 401/403 của Spring có body rỗng);
# thử lại tới hết TIMEOUT.
check() {
  local label="$1" path="$2" want="$3" filter="$4" desc="$5" deadline attempt=0 out body code reason=""
  shift 5
  echo ""
  echo "→ $label"
  deadline=$((SECONDS + TIMEOUT))
  while :; do
    attempt=$((attempt + 1))
    if out="$(curl -sS --max-time 10 -w '\n%{http_code}' "$@" "$BASE$path" 2>&1)"; then
      code="${out##*$'\n'}"; body="${out%$'\n'*}"
      if [[ "$code" =~ ^($want)$ ]]; then
        if [ "$filter" = "-" ] || jq -e "$filter" >/dev/null 2>&1 <<<"$body"; then
          echo "  ✓ ok (lần thử $attempt, HTTP $code): $desc"
          return 0
        fi
        reason="HTTP $code nhưng nội dung không đạt ($desc): ${body:0:200}"
      else
        reason="HTTP $code, mong đợi $want: ${body:0:200}"
      fi
    else
      reason="${out:0:200}"
    fi
    [ "$SECONDS" -lt "$deadline" ] || break
    sleep "$INTERVAL"
  done
  echo "  ✗ FAILED sau $attempt lần thử — $reason"
  return 1
}

# Endpoint NGHIỆP VỤ thật qua gateway (không phải /api/actuator/health — gateway không có route đó).
# productOffering được seed lúc khởi động (Flyway) và CÔNG KHAI (khách chưa đăng nhập vẫn xem gói).
check "productOffering (product-catalog qua api-gateway, công khai)" \
  "/api/tmf-api/productCatalog/v4/productOffering" "200" 'type == "array" and length > 0' "mảng có ≥ 1 gói cước" || fail=1
check "customer KHÔNG token → 401 (auth bật, B-18)" \
  "/api/tmf-api/customerManagement/v4/customer" "401" - "gateway từ chối khi không có token" || fail=1

if [ -n "$TOKEN" ]; then
  AUTH=(-H "Authorization: Bearer $TOKEN")
  check "customer/me với token user customer (customer-service chấp nhận token)" \
    "/api/tmf-api/customerManagement/v4/customer/me" "200|404" 'type == "object"' "200 (có hồ sơ) hoặc 404 (chưa có) — không phải 401/403" "${AUTH[@]}" || fail=1
  check "API quản trị với token user customer → 403 (phân quyền role)" \
    "/api/tmf-api/customerManagement/v4/customer" "403" - "role customer không được liệt kê khách" "${AUTH[@]}" || fail=1
else
  echo ""
  echo "  (bỏ qua các kiểm tra cần đăng nhập — không có SMOKE_TOKEN)"
fi

if [ "$fail" -ne 0 ]; then
  echo ""
  echo "✗ Smoke test FAILED — ít nhất một kiểm tra không đạt."
  exit 1
fi

echo ""
echo "✓ Smoke test passed."
