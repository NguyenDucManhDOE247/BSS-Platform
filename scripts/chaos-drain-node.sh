#!/usr/bin/env bash
# Chaos experiment #2 (Giai đoạn 8, việc 2): drain 1 node — mô phỏng bảo trì/node bị AWS thu hồi
# (spot interruption, patching). Khác chaos-delete-pod.sh: `drain` di dời TOÀN BỘ pod trên 1 node
# CÙNG LÚC, nên đây là bài kiểm PodDisruptionBudget thật — nếu minAvailable của một service sẽ bị
# vi phạm, `kubectl drain` phải TỰ CHẶN LẠI (đúng thiết kế), không phải bug.
#
# Usage:
#   ./scripts/chaos-drain-node.sh              # chọn ngẫu nhiên 1 node
#   ./scripts/chaos-drain-node.sh <node-name>   # chỉ định node
#
# Luôn uncordon lại node ở cuối (kể cả khi drain thất bại giữa chừng), để không quên "khoá" node
# mãi mãi khỏi lịch schedule.
set -euo pipefail

NAMESPACE="${1:+}"; NAMESPACE="bss"
NODE="${1:-}"

echo "→ Context hiện tại: $(kubectl config current-context)"

if [ -z "$NODE" ]; then
  # shellcheck disable=SC2207
  nodes=($(kubectl get nodes -o jsonpath='{.items[*].metadata.name}'))
  if [ "${#nodes[@]}" -lt 2 ]; then
    echo "⚠️  Cluster chỉ có ${#nodes[@]} node — drain node duy nhất sẽ làm TOÀN BỘ pod (kể cả hệ thống)"
    echo "   phải tìm chỗ khác, có thể treo nếu không đâu nhận. Cân nhắc test trên cluster ≥2 node."
  fi
  NODE="${nodes[$RANDOM % ${#nodes[@]}]}"
fi
echo "→ Node bị chọn: $NODE"

echo "→ Pod đang chạy trên node này (namespace $NAMESPACE):"
kubectl -n "$NAMESPACE" get pods -o wide --field-selector "spec.nodeName=$NODE"

echo "→ PDB hiện tại (đây là thứ sẽ bị kiểm tra khi drain):"
kubectl -n "$NAMESPACE" get pdb

cleanup() {
  echo ""
  echo "→ Uncordon $NODE (dù drain có PASS/FAIL, luôn trả node về trạng thái schedule bình thường)."
  kubectl uncordon "$NODE" || true
}
trap cleanup EXIT

echo ""
echo "→ Bắt đầu drain (timeout 180s)..."
start=$SECONDS
if kubectl drain "$NODE" --ignore-daemonsets --delete-emptydir-data --timeout=180s; then
  drain_seconds=$((SECONDS - start))
  echo "✅ Drain thành công sau ${drain_seconds}s — mọi pod đã được di dời sang node khác đúng PDB."
else
  echo "✗ Drain thất bại/timeout — rất có thể PDB minAvailable chặn lại (đúng thiết kế nếu chỉ có"
  echo "  đúng 1 node đủ tài nguyên để nhận pod). Xem: kubectl -n $NAMESPACE get pdb,pods -o wide"
  exit 1
fi

echo ""
echo "→ Pod sau khi drain (đã chuyển sang node khác):"
kubectl -n "$NAMESPACE" get pods -o wide
