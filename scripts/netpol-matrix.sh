#!/usr/bin/env bash
# Ma trận kiểm NetworkPolicy bằng POD SERVICE THẬT (GĐ7 việc 5 → dọn nợ): kind hoặc EKS.
#
#   ./scripts/netpol-matrix.sh [kube-context]      # mặc định: context hiện tại
#
# Vì sao không dùng Pod giả mang nhãn `app=order-management` như bản GĐ7: Service chọn Pod theo đúng nhãn
# đó → Pod giả nhận luôn traffic thật của khách. Ở đây luồng service → service được thử từ BÊN TRONG Pod
# thật (`kubectl exec` + bash `/dev/tcp` — image eclipse-temurin có bash); chỉ "kẻ lạ" là Pod tạm, không
# nhãn nào khớp policy.
#
# Đọc kết quả: OPEN = bắt tay TCP thành công; BLOCKED = hết 3s không bắt tay được (NetworkPolicy DROP gói
# tin → timeout). "Connection refused" (tới được nhưng cổng đóng) được báo riêng là REFUSED — nếu thấy nó
# ở ô mong đợi BLOCKED thì policy KHÔNG chặn, chỉ tình cờ cổng không mở.
#
# Ghi nhớ đã trả giá (GĐ9): enforcement phải tự kiểm — `kubectl apply` NetworkPolicy luôn "thành công" kể
# cả khi CNI không thi hành; và Pod "kẻ lạ" thiếu securityContext bị admission từ chối → "bị chặn" giả.
set -euo pipefail

CTX_ARGS=()
[ -n "${1:-}" ] && CTX_ARGS=(--context "$1")
K() { kubectl "${CTX_ARGS[@]}" "$@"; }

pass=0; fail=0
record() { # tên  mong_đợi  thực_tế
  if [ "$2" = "$3" ]; then pass=$((pass + 1)); printf '  ✓ %-58s %s\n' "$1" "$3"
  else fail=$((fail + 1)); printf '  ✗ %-58s mong %s, thật %s\n' "$1" "$2" "$3"; fi
}

# probe_from_deploy DEPLOY HOST PORT → OPEN|BLOCKED|REFUSED
probe_from_deploy() {
  local rc=0
  K -n bss exec "deploy/$1" -c app -- timeout 3 bash -c "exec 3<>/dev/tcp/$2/$3" >/dev/null 2>&1 || rc=$?
  case $rc in 0) echo OPEN ;; 124) echo BLOCKED ;; *) echo REFUSED ;; esac
}

INTRUDER=netpol-intruder
cleanup() { K -n bss delete pod "$INTRUDER" --ignore-not-found --wait=false >/dev/null 2>&1 || true; }
trap cleanup EXIT

echo "→ Tạo Pod 'kẻ lạ' (nhãn app=$INTRUDER, securityContext restricted)…"
K -n bss run "$INTRUDER" --image=curlimages/curl:8.10.1 --restart=Never --labels="app=$INTRUDER" \
  --overrides='{"spec":{"securityContext":{"runAsNonRoot":true,"runAsUser":100,"seccompProfile":{"type":"RuntimeDefault"}},
    "containers":[{"name":"'"$INTRUDER"'","image":"curlimages/curl:8.10.1","command":["sleep","600"],
    "resources":{"requests":{"cpu":"10m","memory":"16Mi"},"limits":{"cpu":"100m","memory":"64Mi"}},
    "securityContext":{"allowPrivilegeEscalation":false,"readOnlyRootFilesystem":true,"capabilities":{"drop":["ALL"]}}}]}}' \
  >/dev/null
K -n bss wait --for=condition=Ready "pod/$INTRUDER" --timeout=90s >/dev/null

probe_from_intruder() { # HOST PORT
  local code
  code="$(K -n bss exec "$INTRUDER" -- curl -s -m 3 -o /dev/null -w '%{http_code}' "http://$1:$2/" 2>/dev/null || true)"
  case "$code" in 000|"") echo BLOCKED ;; *) echo OPEN ;; esac
}

echo ""
echo "── Luồng service → service THẬT (phải OPEN / BLOCKED đúng như policy)"
record "api-gateway → billing-service (allow-gateway-to-backends)" OPEN    "$(probe_from_deploy api-gateway billing-service 80)"
record "order-management → product-catalog (lấy giá, B-13)"        OPEN    "$(probe_from_deploy order-management product-catalog 80)"
record "order-management → customer-service (/customer/me)"        OPEN    "$(probe_from_deploy order-management customer-service 80)"
record "billing-service → product-catalog (không cần → chặn)"      BLOCKED "$(probe_from_deploy billing-service product-catalog 80)"
record "billing-service → customer-service (không cần → chặn)"     BLOCKED "$(probe_from_deploy billing-service customer-service 80)"

echo ""
echo "── Pod lạ (không nhãn nào khớp policy)"
record "kẻ lạ → product-catalog"                                   BLOCKED "$(probe_from_intruder product-catalog 80)"
record "kẻ lạ → customer-service"                                  BLOCKED "$(probe_from_intruder customer-service 80)"
record "kẻ lạ → billing-service"                                   BLOCKED "$(probe_from_intruder billing-service 80)"
record "kẻ lạ → api-gateway (cửa công khai)"                       OPEN    "$(probe_from_intruder api-gateway 80)"

# Keycloak: AWS (components/keycloak-aws, tier=auth) chỉ cho gateway + backend; kind (tier=edge) công khai
# vì trình duyệt vào qua ingress-nginx.
if K -n bss get svc keycloak >/dev/null 2>&1; then
  tier="$(K -n bss get deploy keycloak -o jsonpath='{.spec.template.metadata.labels.tier}')"
  if [ "$tier" = "auth" ]; then
    record "kẻ lạ → keycloak (AWS: chỉ gateway + backend)"          BLOCKED "$(probe_from_intruder keycloak 8080)"
    record "api-gateway → keycloak (tải JWKS)"                       OPEN    "$(probe_from_deploy api-gateway keycloak 8080)"
  else
    record "kẻ lạ → keycloak (kind: tier=$tier, công khai qua ingress)" OPEN  "$(probe_from_intruder keycloak 8080)"
  fi
fi

echo ""
echo "════ $pass đạt, $fail sai ════"
[ "$fail" -eq 0 ]
