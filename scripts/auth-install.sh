#!/usr/bin/env bash
# Giai đoạn 7, việc 6 (B-18): tạo Secret `keycloak-admin` TRƯỚC khi `kubectl apply -k overlays/local`
# (Keycloak Deployment tham chiếu Secret này — thiếu là Pod CreateContainerConfigError). Không có
# gì khác cần làm riêng: mọi resource khác của Keycloak (Deployment/Service/ConfigMap realm) đã
# là 1 phần của overlays/local/kustomization.yaml, được áp cùng lệnh `kubectl apply -k` bình
# thường của bạn (make ENV=local hoặc kubectl apply -k infrastructure/kubernetes/overlays/local).
#
# CHỈ có bản `kind`. Trên dev/staging/prod (từ Giai đoạn 9 việc 7) Secret `keycloak-admin` KHÔNG do
# script này tạo: Terraform sinh mật khẩu → Secrets Manager → CSI (components/keycloak-aws, ADR-008/011).
#
# Usage: ./scripts/auth-install.sh kind
set -euo pipefail

ENV="${1:-}"
[ "$ENV" = "kind" ] || { echo "Usage: $0 kind   (AWS: Secret keycloak-admin đến từ Terraform + CSI — không cần script này)" >&2; exit 2; }

CTX="kind-bss"

log()  { echo "→ $*"; }
ok()   { echo "✓ $*"; }
fail() { echo "✗ FAIL: $*" >&2; exit 1; }

command -v kubectl >/dev/null 2>&1 || fail "không tìm thấy 'kubectl' trên PATH"
command -v openssl >/dev/null 2>&1 || fail "cần openssl để sinh mật khẩu admin Keycloak"

# Cluster kind MỚI chưa có namespace `bss` (overlay tạo nó ở lần apply đầu) → phải tạo trước khi đặt
# Secret vào. Dùng đúng file của base (nhãn Pod Security `restricted`) để lần apply overlay sau khớp.
# Lỗi thật 2026-09-30: bản cũ `create secret … | grep … || true` NUỐT lỗi "namespaces bss not found"
# và vẫn in "Sẵn sàng" → Pod Keycloak CreateContainerConfigError (đúng kiểu lỗi B-52).
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
kubectl --context "$CTX" apply -f "$ROOT/infrastructure/kubernetes/base/namespace.yaml" >/dev/null

if kubectl --context "$CTX" -n bss get secret keycloak-admin >/dev/null 2>&1; then
  log "Secret keycloak-admin đã có — giữ nguyên"
else
  log "Tạo Secret keycloak-admin (mật khẩu ngẫu nhiên)"
  kubectl --context "$CTX" -n bss create secret generic keycloak-admin \
    --from-literal=username=admin \
    --from-literal=password="$(openssl rand -base64 18 | tr -d '/+=')" >/dev/null
fi
kubectl --context "$CTX" -n bss get secret keycloak-admin >/dev/null || fail "Secret keycloak-admin vẫn chưa có"

ok "Sẵn sàng — chạy tiếp: kubectl apply -k infrastructure/kubernetes/overlays/local"
cat <<'EOF'

Mật khẩu admin Keycloak (đăng nhập http://bss.localhost/auth/admin):
  kubectl -n bss get secret keycloak-admin -o jsonpath='{.data.password}' | base64 -d; echo

2 user thử sẵn (realm "bss", khai trong overlays/local/keycloak/bss-users-0.json — KHÔNG phải mật
khẩu thật, chỉ để kiểm chứng cục bộ):
  admin1    / admin1pass    (role: admin)
  customer1 / customer1pass (role: customer)

Xem docs/runbooks/auth.md để lấy token thật + gọi thử API qua gateway.
EOF
