#!/usr/bin/env bash
# Creates (or reuses) the "bss" kind cluster and installs the 2 cluster-wide addons Giai đoạn 2
# needs before any BSS manifest can go in: ingress-nginx (so http://bss.localtest.me works with
# no /etc/hosts edit and no `kubectl port-forward`) and metrics-server (HPA reads CPU/memory from
# it — B-43, without it `kubectl get hpa` shows <unknown> forever and never scales).
#
# Same discipline as scripts/e2e-local.sh: no `|| true` hiding a real failure. Safe to re-run —
# every step is idempotent (`kind create cluster` no-ops if "bss" already exists; `kubectl apply`
# and `helm upgrade --install` are both apply-not-recreate).
#
# Usage: ./scripts/kind-up.sh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLUSTER=bss

log()  { echo "→ $*"; }
fail() { echo "✗ FAIL: $*" >&2; exit 1; }
ok()   { echo "✓ $*"; }

command -v kind    >/dev/null 2>&1 || fail "kind not found on PATH — see learning/nhat-ky-hoc-tap.md for how this session installed it"
command -v kubectl >/dev/null 2>&1 || fail "kubectl not found on PATH"
command -v helm    >/dev/null 2>&1 || fail "helm not found on PATH"

if kind get clusters 2>/dev/null | grep -qx "$CLUSTER"; then
  log "kind cluster '$CLUSTER' already exists — reusing it"
else
  log "Creating kind cluster '$CLUSTER' (config: kind.yaml)…"
  kind create cluster --name "$CLUSTER" --config "$ROOT_DIR/kind.yaml"
fi

# Bug thật (phát hiện khi người dùng tự chạy script trên WSL Ubuntu — Docker Desktop's WSL2
# integration dùng CHUNG 1 Docker daemon cho cả Windows host lẫn mọi WSL distro, nên `kind get
# clusters` (chỉ đọc container Docker theo nhãn) thấy đúng cluster dù nó được TẠO từ một hệ điều
# hành/kubeconfig khác — nhưng `~/.kube/config` là 1 file THEO TỪNG filesystem, không dùng chung.
# Nhánh "reusing it" ở trên chỉ bỏ qua bước tạo cluster, KHÔNG tự đảm bảo context tồn tại trong
# kubeconfig hiện tại → bước tiếp theo `kubectl --context kind-bss` báo "context does not exist"
# dù cluster rõ ràng đang chạy. `kind export kubeconfig` ghi (hoặc ghi đè) đúng context này —
# chạy vô điều kiện ở cả 2 nhánh, không chỉ khi tạo mới, để luôn tự sửa được tình huống này.
log "Ensuring the '$CLUSTER' kubeconfig context exists (kind export kubeconfig)…"
kind export kubeconfig --name "$CLUSTER"

log "Switching kubectl context to kind-$CLUSTER for the rest of this script…"
KCTX="kind-$CLUSTER"

log "Installing ingress-nginx (kind-specific manifest — hostPort, no cloud LoadBalancer needed)…"
kubectl --context "$KCTX" apply -f https://raw.githubusercontent.com/kubernetes-sigs/kind/main/site/static/examples/ingress/deploy-ingress-nginx.yaml
log "Waiting for the ingress-nginx controller pod to be Ready (up to 3 min)…"
kubectl --context "$KCTX" -n ingress-nginx wait --for=condition=ready pod \
  --selector=app.kubernetes.io/component=controller --timeout=180s
ok "ingress-nginx ready"

log "Installing metrics-server (needed by every HPA in this repo — B-43)…"
helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/ >/dev/null
helm repo update metrics-server >/dev/null
# --kubelet-insecure-tls: kind's kubelet serving cert is self-signed; metrics-server refuses it
# by default and every `kubectl top` stays empty until this flag is set.
helm --kube-context "$KCTX" upgrade --install metrics-server metrics-server/metrics-server \
  --version 3.14.0 -n kube-system \
  --set args={--kubelet-insecure-tls}
kubectl --context "$KCTX" -n kube-system rollout status deployment/metrics-server --timeout=120s
ok "metrics-server installed"

echo ""
ok "kind cluster '$CLUSTER' ready. Next steps:"
echo "   1. docker build the 7 images with tag :local (see Makefile target build-images)"
echo "   2. for s in customer-service product-catalog order-management billing-service api-gateway web-portal admin-console; do"
echo "        kind load docker-image bss/\$s:local --name $CLUSTER; done"
echo "   3. kubectl --context $KCTX apply -k infrastructure/kubernetes/overlays/local"
echo "   4. ./scripts/e2e-kind.sh"
