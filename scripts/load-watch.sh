#!/usr/bin/env bash
# Ghi trạng thái cluster mỗi INTERVAL giây trong lúc chạy tải — để giải thích LỖI, không chỉ đếm lỗi.
# Sinh ra từ ADR-010: "7,9% lỗi dưới 700 req/s có Karpenter" kèm alert BssPodCrashLooping cho api-gateway,
# nhưng cluster đã destroy trước khi ai kịp xem Pod restart VÌ SAO (OOMKilled? liveness fail?).
#
#   ./scripts/load-watch.sh [kube-context] [phút] > results/load-watch.log &
#   BASE_URL=... k6 run -e STAGES=200,325,450,575,700 tests/load/dev-threshold.js
#
# Mỗi mẫu in: số node (Karpenter/managed), Pod Pending, replica HPA, và MỌI container đã restart kèm
# lastState (reason, exitCode, finishedAt). Cuối cùng in các Event cảnh báo của namespace bss.
set -euo pipefail

CTX_ARGS=()
[ -n "${1:-}" ] && CTX_ARGS=(--context "$1")
MINUTES="${2:-15}"
INTERVAL="${INTERVAL:-15}"
K() { kubectl "${CTX_ARGS[@]}" "$@"; }

end=$(( $(date +%s) + MINUTES * 60 ))
while [ "$(date +%s)" -lt "$end" ]; do
  ts=$(date +%H:%M:%S)
  nodes=$(K get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')
  karp=$(K get nodes -l karpenter.sh/nodepool --no-headers 2>/dev/null | wc -l | tr -d ' ')
  pending=$(K -n bss get pods --field-selector=status.phase=Pending --no-headers 2>/dev/null | wc -l | tr -d ' ')
  hpa=$(K -n bss get hpa --no-headers 2>/dev/null | awk '{printf "%s=%s(%s) ", $1, $(NF-1), $4}')
  echo "$ts nodes=$nodes karpenter=$karp pending=$pending | $hpa"
  K -n bss get pods -o json 2>/dev/null | jq -r '
    .items[] | .metadata.name as $p | (.status.containerStatuses // [])[]
    | select(.restartCount > 0)
    | "   restart \($p) x\(.restartCount) last=\(.lastState.terminated.reason // "?")/exit=\(.lastState.terminated.exitCode // "?") at=\(.lastState.terminated.finishedAt // "?")"'
  sleep "$INTERVAL"
done

echo "=== Events (Warning) trong namespace bss"
K -n bss get events --field-selector type=Warning --sort-by=.lastTimestamp \
  -o custom-columns=TIME:.lastTimestamp,REASON:.reason,OBJ:.involvedObject.name,MSG:.message --no-headers 2>/dev/null \
  | cut -c1-220 | tail -60
