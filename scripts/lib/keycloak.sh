# shellcheck shell=bash
# Hàm dùng chung để nói chuyện với Admin REST API của Keycloak trên MỌI môi trường (kind, dev, staging,
# prod). Được `source` bởi scripts/e2e-flow.sh, scripts/e2e-browser.sh, scripts/admin-user.sh.
#
# Vì sao có file này: trên AWS `/auth/admin` cố ý KHÔNG có route ra ALB (ADR-012) → mọi việc quản trị
# (tạo user, gán role) phải đi bằng `kubectl port-forward` (qua API server EKS, có TLS + IAM). Trên kind
# Keycloak nằm sau ingress-nginx ở `http://bss.localhost/auth` nên gọi thẳng. Mật khẩu admin master realm
# đọc từ K8s Secret `keycloak-admin` (kind: auth-install.sh sinh; AWS: Terraform → Secrets Manager → CSI).
#
# Token của user thử cũng lấy qua KC_URL (password grant, client `api-gateway` — client DUY NHẤT bật Direct
# Access Grants, ADR-008 QĐ 1): trên AWS nghĩa là qua port-forward, nên không mật khẩu nào đi ra internet;
# `iss` của token vẫn là https://<host>/auth/realms/bss vì KC_HOSTNAME là URL đầy đủ (ADR-012).
#
# Biến do kc_connect đặt: KCTX (kube context), KC_URL (…/auth). Biến do kc_master_login đặt: KC_MASTER.

KC_PF_PID=""

# kc_connect ENV — kind | dev | staging | prod
kc_connect() {
  local env="$1" port="${KC_PORT:-18555}"
  # KC_PORT: KHÔNG dùng 18080 trên Windows — nằm trong dải cổng Hyper-V giữ riêng (xem smoke.sh SMOKE_KC_PORT).
  case "$env" in
    kind)
      KCTX="kind-bss"
      KC_URL="http://bss.localhost/auth"
      ;;
    dev|staging|prod)
      aws eks update-kubeconfig --region "${AWS_REGION:-ap-southeast-1}" --name "bss-$env-eks" >/dev/null
      KCTX="$(kubectl config current-context)"
      kubectl --context "$KCTX" -n bss rollout status deployment/keycloak --timeout=300s >&2
      kubectl --context "$KCTX" -n bss port-forward svc/keycloak "$port:8080" >/dev/null 2>&1 &
      KC_PF_PID=$!
      KC_URL="http://127.0.0.1:$port/auth"
      ;;
    *) echo "✗ môi trường phải là kind|dev|staging|prod, nhận '$env'" >&2; return 1 ;;
  esac
  for _ in $(seq 1 30); do
    curl -fsS -o /dev/null "$KC_URL/realms/bss" 2>/dev/null && return 0
    sleep 1
  done
  echo "✗ không tới được Keycloak ở $KC_URL" >&2
  return 1
}

kc_disconnect() {
  [ -z "$KC_PF_PID" ] || kill "$KC_PF_PID" 2>/dev/null || true
  KC_PF_PID=""
}

kc_master_login() {
  local u p
  u="$(kubectl --context "$KCTX" -n bss get secret keycloak-admin -o jsonpath='{.data.username}' | base64 -d)"
  p="$(kubectl --context "$KCTX" -n bss get secret keycloak-admin -o jsonpath='{.data.password}' | base64 -d)"
  KC_MASTER="$(curl -fsS "$KC_URL/realms/master/protocol/openid-connect/token" -d grant_type=password \
    -d client_id=admin-cli --data-urlencode "username=$u" --data-urlencode "password=$p" | jq -r '.access_token')"
  [ -n "$KC_MASTER" ] && [ "$KC_MASTER" != "null" ] || { echo "✗ không đăng nhập được Keycloak master (Secret keycloak-admin?)" >&2; return 1; }
}

# kc_admin METHOD PATH [curl args…] — PATH tính từ /admin/realms/bss
kc_admin() {
  local method="$1" path="$2"; shift 2
  curl -fsS -X "$method" -H "Authorization: Bearer $KC_MASTER" "$KC_URL/admin/realms/bss$path" "$@"
}

# kc_user_id USERNAME → id (rỗng nếu chưa có)
kc_user_id() {
  kc_admin GET "/users?username=$1&exact=true" | jq -r '.[0].id // empty'
}

# kc_create_user USERNAME EMAIL PASSWORD TEMPORARY(true|false) → id
# TEMPORARY=true: Keycloak bắt đổi mật khẩu ở lần đăng nhập đầu (tài khoản người thật). User thử dùng false
# vì password grant từ chối user còn "required action".
kc_create_user() {
  jq -n --arg u "$1" --arg e "$2" --arg p "$3" --argjson t "$4" '{
    username: $u, email: $e, firstName: "BSS", lastName: $u, enabled: true, emailVerified: true,
    credentials: [{ type: "password", value: $p, temporary: $t }]
  }' | kc_admin POST /users -H 'Content-Type: application/json' -d @- >/dev/null
  kc_user_id "$1"
}

# kc_make_staff USER_ID — role `admin`, BỎ `default-roles-bss` (mang role customer): nhân viên không phải
# khách hàng, không đặt hàng hộ khách (order-management chỉ cho role customer POST đơn — SecurityConfig).
kc_make_staff() {
  local id="$1" admin def
  admin="$(kc_admin GET /roles/admin)"
  def="$(kc_admin GET /roles/default-roles-bss)"
  echo "[$admin]" | kc_admin POST "/users/$id/role-mappings/realm" -H 'Content-Type: application/json' -d @- >/dev/null
  echo "[$def]" | kc_admin DELETE "/users/$id/role-mappings/realm" -H 'Content-Type: application/json' -d @- >/dev/null
}

kc_delete_user() {
  [ -z "$1" ] || kc_admin DELETE "/users/$1" >/dev/null || true
}

# kc_user_token USERNAME PASSWORD → access token
kc_user_token() {
  local tok
  tok="$(curl -fsS "$KC_URL/realms/bss/protocol/openid-connect/token" -d grant_type=password -d client_id=api-gateway \
    --data-urlencode "username=$1" --data-urlencode "password=$2" | jq -r '.access_token')"
  [ -n "$tok" ] && [ "$tok" != "null" ] || { echo "✗ không lấy được token cho $1" >&2; return 1; }
  echo "$tok"
}

kc_random_password() {
  # ≥ 1 chữ hoa/thường/số/ký tự đặc biệt: an toàn nếu realm sau này bật password policy.
  echo "$(openssl rand -base64 18 | tr -d '/+=')Aa1!"
}
