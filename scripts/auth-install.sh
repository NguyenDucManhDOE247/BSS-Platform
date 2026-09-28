#!/usr/bin/env bash
# Giai đoạn 7, việc 6 (B-18): tạo Secret `keycloak-admin` TRƯỚC khi `kubectl apply -k overlays/local`
# (Keycloak Deployment tham chiếu Secret này — thiếu là Pod CreateContainerConfigError). Không có
# gì khác cần làm riêng: mọi resource khác của Keycloak (Deployment/Service/ConfigMap realm) đã
# là 1 phần của overlays/local/kustomization.yaml, được áp cùng lệnh `kubectl apply -k` bình
# thường của bạn (make ENV=local hoặc kubectl apply -k infrastructure/kubernetes/overlays/local).
#
# CHỈ có bản `kind` — dev/staging/prod chưa có Keycloak (Cognito hoặc Keycloak Terraform-hóa là
# việc riêng, cần AWS thật, xem docs/runbooks/auth.md mục "Còn lại").
#
# Usage: ./scripts/auth-install.sh kind
set -euo pipefail

ENV="${1:-}"
[ "$ENV" = "kind" ] || { echo "Usage: $0 kind   (dev/staging/prod chưa hỗ trợ — xem docs/runbooks/auth.md)" >&2; exit 2; }

CTX="kind-bss"

log()  { echo "→ $*"; }
ok()   { echo "✓ $*"; }
fail() { echo "✗ FAIL: $*" >&2; exit 1; }

command -v kubectl >/dev/null 2>&1 || fail "không tìm thấy 'kubectl' trên PATH"
command -v openssl >/dev/null 2>&1 || fail "cần openssl để sinh mật khẩu admin Keycloak"

if kubectl --context "$CTX" -n bss get secret keycloak-admin >/dev/null 2>&1; then
  log "Secret keycloak-admin đã có — giữ nguyên"
else
  log "Tạo Secret keycloak-admin (mật khẩu ngẫu nhiên)"
  kubectl --context "$CTX" -n bss create secret generic keycloak-admin \
    --from-literal=username=admin \
    --from-literal=password="$(openssl rand -base64 18 | tr -d '/+=')" 2>&1 | grep -v "^$" || true
fi

ok "Sẵn sàng — chạy tiếp: kubectl apply -k infrastructure/kubernetes/overlays/local"
cat <<'EOF'

Mật khẩu admin Keycloak (đăng nhập http://bss.localhost/auth/admin):
  kubectl -n bss get secret keycloak-admin -o jsonpath='{.data.password}' | base64 -d; echo

2 user thử sẵn (realm "bss", khai trong overlays/local/keycloak/realm-bss.json — KHÔNG phải mật
khẩu thật, chỉ để kiểm chứng cục bộ):
  admin1    / admin1pass    (role: admin)
  customer1 / customer1pass (role: customer)

Xem docs/runbooks/auth.md để lấy token thật + gọi thử API qua gateway.
EOF
