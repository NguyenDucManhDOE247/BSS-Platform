#!/usr/bin/env bash
# Cấp tài khoản NHÂN VIÊN (role `admin`) cho admin-console — cách làm như vận hành thật:
#
#   ./scripts/admin-user.sh <kind|dev|staging|prod> <username> <email>
#   ./scripts/admin-user.sh <env> <username> <email> --reset-password     # quên mật khẩu → cấp mật khẩu tạm mới
#
# - Realm trên AWS KHÔNG có user nào (ADR-008 QĐ 6 — user mẫu admin1/customer1 chỉ có ở kind), và
#   `/auth/admin` cố ý không ra ALB (ADR-012) → không ai "tự đăng ký làm admin" được; nhân viên do người
#   vận hành cấp, qua `kubectl port-forward` (cần quyền vào cluster = IAM + EKS access entry).
# - Mật khẩu TẠM ngẫu nhiên, in ra MỘT lần ở terminal này; Keycloak bắt đổi ở lần đăng nhập đầu
#   (`temporary: true`) → người vận hành không biết mật khẩu thật của nhân viên.
# - Role `admin` và BỎ `default-roles-bss` (mang `customer`): nhân viên không phải khách hàng.
# - Idempotent: user đã có → chỉ bảo đảm đúng role (và cấp mật khẩu tạm mới nếu có --reset-password).
#
# Môi trường staging/prod là ephemeral (ADR-006): mỗi lần dựng lại là DB Keycloak mới → chạy lại lệnh này.
set -euo pipefail

ENV="${1:-}"; USERNAME="${2:-}"; EMAIL="${3:-}"; RESET="${4:-}"
if [ -z "$ENV" ] || [ -z "$USERNAME" ] || [ -z "$EMAIL" ]; then
  echo "Usage: $0 <kind|dev|staging|prod> <username> <email> [--reset-password]" >&2
  exit 1
fi
# shellcheck source=lib/keycloak.sh
. "$(dirname "$0")/lib/keycloak.sh"
trap kc_disconnect EXIT

kc_connect "$ENV"
kc_master_login

PASS=""
ID="$(kc_user_id "$USERNAME")"
if [ -z "$ID" ]; then
  PASS="$(kc_random_password)"
  ID="$(kc_create_user "$USERNAME" "$EMAIL" "$PASS" true)"
  [ -n "$ID" ] || { echo "✗ tạo user thất bại" >&2; exit 1; }
  echo "✓ đã tạo nhân viên $USERNAME"
else
  echo "✓ $USERNAME đã có — bảo đảm role"
  if [ "$RESET" = "--reset-password" ]; then
    PASS="$(kc_random_password)"
    jq -n --arg p "$PASS" '{type:"password", value:$p, temporary:true}' \
      | kc_admin PUT "/users/$ID/reset-password" -H 'Content-Type: application/json' -d @- >/dev/null
  fi
fi
kc_make_staff "$ID"

ROLES="$(kc_admin GET "/users/$ID/role-mappings/realm/composite" | jq -r '[.[].name] | sort | join(", ")')"
case ", $ROLES," in *", admin,"*) ;; *) echo "✗ role sau khi gán: $ROLES — thiếu admin" >&2; exit 1 ;; esac
case ", $ROLES," in *", customer,"*) echo "✗ nhân viên vẫn mang role customer: $ROLES" >&2; exit 1 ;; esac
echo "✓ role: $ROLES"

if [ "$ENV" = "kind" ]; then
  SITE="http://bss.localhost"
else
  SITE="https://$(kubectl --context "$KCTX" -n bss get ingress bss-ingress -o jsonpath='{.spec.rules[0].host}')"
fi
echo ""
echo "admin-console: $SITE/admin/  — user: $USERNAME"
if [ -n "$PASS" ]; then
  echo "Mật khẩu TẠM (chỉ hiện lần này, đổi ngay ở lần đăng nhập đầu): $PASS"
fi
