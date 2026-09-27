#!/usr/bin/env bash
# Chaos experiment #1 (Giai đoạn 8, việc 2): xóa NGẪU NHIÊN 1 pod của 1 service, đo thời gian
# tự hồi phục, và trong lúc đó bắn liên tục vào endpoint nghiệp vụ thật để chứng minh KHÔNG mất
# request — đây chính là lý do ta cần ≥ 2 replica + PDB (minAvailable) thay vì chỉ tin vào
# "Kubernetes tự dựng lại pod".
#
# Usage:
#   ./scripts/chaos-delete-pod.sh [namespace] [app-label]
#   ./scripts/chaos-delete-pod.sh bss order-management
#
# Biến môi trường:
#   SMOKE_BASE_URL   base URL để bắn traffic song song trong lúc chaos (mặc định: http://localhost:8080,
#                     dùng với `kubectl -n bss port-forward svc/api-gateway 8080:8080` chạy sẵn ở terminal khác)
#   PROBE_PATH        endpoint nghiệp vụ để bắn (mặc định: /api/tmf-api/productCatalog/v4/productOffering)
#
# An toàn: chỉ xóa ĐÚNG 1 pod (không phải toàn bộ Deployment) — ReplicaSet controller sẽ tự tạo
# lại pod thay thế, đây chính là hành vi ta muốn quan sát, không phải một sự cố thật.
set -euo pipefail

NAMESPACE="${1:-bss}"
APP_LABEL="${2:-order-management}"
BASE_URL="${SMOKE_BASE_URL:-http://localhost:8080}"
PROBE_PATH="${PROBE_PATH:-/api/tmf-api/productCatalog/v4/productOffering}"

echo "→ Context hiện tại: $(kubectl config current-context)"
echo "→ Namespace=$NAMESPACE  app=$APP_LABEL"

pods_before=$(kubectl -n "$NAMESPACE" get pods -l "app=$APP_LABEL" -o jsonpath='{.items[*].metadata.name}')
# shellcheck disable=SC2206
pods_arr=($pods_before)
count_before=${#pods_arr[@]}
if [ "$count_before" -lt 1 ]; then
  echo "✗ Không tìm thấy pod nào với label app=$APP_LABEL trong namespace $NAMESPACE."
  exit 1
fi
if [ "$count_before" -lt 2 ]; then
  echo "⚠️  Chỉ có $count_before pod (replicas<2) — xóa pod này SẼ gây gián đoạn thật, không phải bài học"
  echo "   'zero-downtime nhờ nhiều replica'. Cân nhắc chạy trên overlay có ≥2 replica trước."
fi

victim="${pods_arr[$RANDOM % ${#pods_arr[@]}]}"
echo "→ Pod bị chọn để xóa: $victim"

# --- Bắn traffic nền song song, ghi log request lỗi (nếu có) ---
probe_log="$(mktemp)"
probe() {
  local deadline=$((SECONDS + 30))
  while [ "$SECONDS" -lt "$deadline" ]; do
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 "$BASE_URL$PROBE_PATH" || echo "000")
    echo "$(date +%T.%N) $code" >> "$probe_log"
    sleep 0.2
  done
}
probe &
probe_pid=$!

start=$SECONDS
kubectl -n "$NAMESPACE" delete pod "$victim" --wait=false
echo "→ Đã gửi lệnh xóa lúc t=0s. Đang chờ pod thay thế Ready..."

deadline=$((SECONDS + 120))
while :; do
  # Đếm CHỈ những pod KHÁC pod vừa xóa. Lý do: sau `delete --wait=false`, pod cũ bước vào
  # Terminating nhưng container của nó có thể vẫn báo containerStatuses[0].ready=true trong
  # suốt grace period (SIGTERM không lập tức lật cờ Ready) — nếu đếm cả nó, vòng lặp sẽ thoát
  # NGAY LẬP TỨC (đo được "0s hồi phục" giả), trước khi pod thay thế thật sự tồn tại. Bug này
  # đã tự bắt được khi chạy thật lần đầu (2026-09-27) — xem nhật ký.
  ready_count=$(kubectl -n "$NAMESPACE" get pods -l "app=$APP_LABEL" -o json \
    | jq --arg victim "$victim" '[.items[] | select(.metadata.name != $victim) | select(.status.containerStatuses[0].ready == true)] | length')
  if [ "$ready_count" -ge "$count_before" ]; then
    break
  fi
  if [ "$SECONDS" -ge "$deadline" ]; then
    echo "✗ Sau 120s vẫn chưa đủ $count_before pod Ready trở lại — kiểm tra: kubectl -n $NAMESPACE get pods -l app=$APP_LABEL"
    kill "$probe_pid" 2>/dev/null || true
    wait "$probe_pid" 2>/dev/null || true
    exit 1
  fi
  sleep 2
done
recovery_seconds=$((SECONDS - start))

wait "$probe_pid" 2>/dev/null || true

echo ""
echo "=== Kết quả ==="
echo "Thời gian tới khi đủ $count_before/$count_before pod Ready trở lại: ${recovery_seconds}s"
total_probes=$(wc -l < "$probe_log")
failed_probes=$(grep -vc '200$' "$probe_log" || true)
echo "Request bắn song song trong 30s đầu: $total_probes, không phải HTTP 200: $failed_probes"
if [ "$failed_probes" -eq 0 ]; then
  echo "✅ 0 request lỗi trong lúc pod bị xóa và tự hồi phục — PDB + ≥2 replica hoạt động đúng."
else
  echo "⚠️  Có $failed_probes/$total_probes request lỗi — xem $probe_log; nếu count_before<2 đây là kỳ vọng."
fi
rm -f "$probe_log"
