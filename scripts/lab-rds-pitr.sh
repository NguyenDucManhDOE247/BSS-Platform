#!/usr/bin/env bash
# Lab 09 — khôi phục RDS về một thời điểm (PITR) sau một sự cố dữ liệu THẬT, rồi sửa đúng chỗ hỏng.
#
#   ./scripts/lab-rds-pitr.sh [dev]          # cần: dev EKS đang chạy + đã deploy (product-catalog Running)
#   KEEP=1 ./scripts/lab-rds-pitr.sh         # giữ instance khôi phục lại (mặc định XÓA cuối lab)
#
# Kịch bản (docs/labs/09-rds-pitr.md): một lệnh SQL chạy nhầm đặt giá MỌI gói cước về 0₫ — khách thấy ngay
# trên API. Không "rollback cả DB" (mất mọi thứ ghi sau thời điểm đó: đơn hàng, khách mới…), mà:
#   1. khôi phục SANG MỘT INSTANCE MỚI ở thời điểm ngay trước sự cố (RDS point-in-time restore);
#   2. đọc giá đúng từ instance đó, sửa ĐÚNG cột bị hỏng trên DB đang chạy (trong 1 transaction);
#   3. xóa instance tạm.
# 💰 Instance tạm db.t3.micro ~$0.02/giờ, sống ~15–25 phút. Tên `bss-<env>-pg-pitr` → orphan_finder.py bắt
# được nếu lỡ quên xóa.
#
# SQL chạy trong 1 Pod tạm (postgres:16-alpine, uid 70, PSS restricted) bằng TÀI KHOẢN CỦA SERVICE
# (`product-db-credentials`, do Secrets Store CSI đồng bộ) — không dùng master: đúng quyền tối thiểu, và
# master (rds_superuser) vốn không đọc được bảng do product_svc sở hữu.
set -euo pipefail

ENV="${1:-dev}"
REGION="${AWS_REGION:-ap-southeast-1}"
SRC="bss-$ENV-pg"
NEW="$SRC-pitr"
POD="rds-pitr-lab"
K() { kubectl -n bss "$@"; }
log() { printf '\n\033[1m[%s] %s\033[0m\n' "$(date +%H:%M:%S)" "$*"; }
die() { echo "✗ $*" >&2; exit 1; }
rds() { aws rds --region "$REGION" "$@"; }
# psql trong Pod. $1 = host (rỗng = DB đang chạy), SQL qua stdin.
psql_in() { K exec -i "$POD" -- sh -c "PGHOST=\${1:-\$PGHOST} psql -v ON_ERROR_STOP=1 -At -F '|'" _ "${1:-}"; }

cleanup() {
  K delete pod "$POD" --ignore-not-found --wait=false >/dev/null 2>&1 || true
}
trap cleanup EXIT

# ── 0. Kiểm điều kiện ────────────────────────────────────────────────────────
log "0. Kiểm $SRC (automated backup phải bật thì mới PITR được)"
read -r STATUS RETENTION SUBNETS PGROUP CLASS < <(rds describe-db-instances --db-instance-identifier "$SRC" \
  --query 'DBInstances[0].[DBInstanceStatus,BackupRetentionPeriod,DBSubnetGroup.DBSubnetGroupName,DBParameterGroups[0].DBParameterGroupName,DBInstanceClass]' --output text)
SGS=$(rds describe-db-instances --db-instance-identifier "$SRC" --query 'DBInstances[0].VpcSecurityGroups[].VpcSecurityGroupId' --output text)
read -ra SG_IDS <<< "$SGS" # có thể nhiều SG (cách nhau bằng tab) → mảng, không dựa vào word splitting
echo "status=$STATUS retention=${RETENTION}d subnet-group=$SUBNETS param-group=$PGROUP class=$CLASS sg=$SGS"
[ "$STATUS" = available ] || die "$SRC chưa available"
[ "$RETENTION" -ge 1 ] || die "BackupRetentionPeriod=0 — không có automated backup, không PITR được"
rds describe-db-instances --db-instance-identifier "$NEW" >/dev/null 2>&1 && die "$NEW đã tồn tại — xóa trước khi chạy lại"

# ── 1. Pod psql ──────────────────────────────────────────────────────────────
log "1. Tạo Pod psql tạm (PSS restricted, tài khoản product_svc)"
# Manifest đầy đủ thay vì `kubectl run --overrides`: lần chạy đầu (2026-10-01) phần securityContext trong
# --overrides KHÔNG được áp → PSS restricted của namespace bss từ chối Pod (đúng việc của nó).
K apply -f - >/dev/null <<YAML
apiVersion: v1
kind: Pod
metadata:
  name: $POD
  namespace: bss
  labels: { app: $POD }
  # Lần chạy thật 2026-10-01: Karpenter gom node "Underutilized" (còn sót từ đợt load test trước) và ĐUỔI luôn Pod
  # trần này giữa lab (Karpenter v1 evict cả Pod không có controller) — lab chết ở bước 6, DB đang chạy vẫn 0₫.
  # Tác vụ chạy lâu trên cụm có Karpenter phải xin "đừng gom node của tôi":
  annotations: { karpenter.sh/do-not-disrupt: "true" }
spec:
  restartPolicy: Never
  securityContext:
    runAsNonRoot: true
    runAsUser: 70
    runAsGroup: 70
    seccompProfile: { type: RuntimeDefault }
  containers:
    - name: psql
      image: postgres:16-alpine
      command: ["sleep", "3600"]
      env:
        - { name: PGHOST,     valueFrom: { secretKeyRef: { name: product-db-credentials, key: host } } }
        - { name: PGPORT,     valueFrom: { secretKeyRef: { name: product-db-credentials, key: port } } }
        - { name: PGDATABASE, valueFrom: { secretKeyRef: { name: product-db-credentials, key: dbname } } }
        - { name: PGUSER,     valueFrom: { secretKeyRef: { name: product-db-credentials, key: username } } }
        - { name: PGPASSWORD, valueFrom: { secretKeyRef: { name: product-db-credentials, key: password } } }
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities: { drop: ["ALL"] }
      resources:
        requests: { cpu: 50m, memory: 64Mi }
        limits: { cpu: 200m, memory: 128Mi }
YAML
K wait --for=condition=Ready "pod/$POD" --timeout=180s >/dev/null
echo "✓ Pod sẵn sàng"

QUERY="SELECT id, name, price_amount FROM product_offering ORDER BY id;"

# ── 2. Ảnh chụp trước sự cố ──────────────────────────────────────────────────
log "2. Giá hiện tại (trước sự cố)"
BASELINE=$(echo "$QUERY" | psql_in)
echo "$BASELINE"
N=$(echo "$BASELINE" | grep -c . || true)
[ "$N" -gt 0 ] || die "product_offering rỗng"

# PITR chỉ khôi phục được tới "LatestRestorableTime" (thường trễ ~5 phút so với hiện tại). Chọn mốc khôi phục
# sau khi ảnh chụp đã được ghi, và cách sự cố 1 khoảng đủ rõ.
sleep 60
T_GOOD=$(date -u +%Y-%m-%dT%H:%M:%SZ)
log "Mốc khôi phục T_GOOD = $T_GOOD (UTC) — giờ chờ 60s rồi gây sự cố"
sleep 60

# ── 3. Sự cố ─────────────────────────────────────────────────────────────────
log "3. SỰ CỐ: UPDATE product_offering SET price_amount = 0  (một lệnh chạy nhầm, không có WHERE)"
T_ACCIDENT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
echo "UPDATE product_offering SET price_amount = 0;" | psql_in
echo "$QUERY" | psql_in | head -5
ALB=$(K get ingress bss-ingress -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)
if [ -n "$ALB" ]; then
  echo "Khách thấy gì trên API (http://$ALB):"
  curl -fsS "http://$ALB/api/tmf-api/productCatalog/v4/productOffering?limit=3" | jq -c '[.[] | {name, priceAmount}]' || true
fi

# ── 4. Chờ tới khi mốc khôi phục nằm trong vùng PITR ─────────────────────────
log "4. Chờ LatestRestorableTime ≥ $T_GOOD"
for _ in $(seq 1 40); do
  LRT=$(rds describe-db-instances --db-instance-identifier "$SRC" --query 'DBInstances[0].LatestRestorableTime' --output text)
  echo "   LatestRestorableTime=$LRT"
  [ "$(date -u -d "$LRT" +%s)" -ge "$(date -u -d "$T_GOOD" +%s)" ] && break
  sleep 30
done
[ "$(date -u -d "$LRT" +%s)" -ge "$(date -u -d "$T_GOOD" +%s)" ] || die "quá 20 phút mà chưa restore tới $T_GOOD được"

# ── 5. Khôi phục sang instance MỚI ───────────────────────────────────────────
log "5. restore-db-instance-to-point-in-time → $NEW @ $T_GOOD"
T0=$(date +%s)
rds restore-db-instance-to-point-in-time \
  --source-db-instance-identifier "$SRC" --target-db-instance-identifier "$NEW" \
  --restore-time "$T_GOOD" --db-instance-class db.t3.micro --no-multi-az --no-publicly-accessible \
  --db-subnet-group-name "$SUBNETS" --vpc-security-group-ids "${SG_IDS[@]}" --db-parameter-group-name "$PGROUP" \
  --no-deletion-protection \
  --tags Key=Project,Value=bss-platform Key=Environment,Value="$ENV" Key=ManagedBy,Value=lab-rds-pitr >/dev/null
echo "   đang khôi phục… (thường 10–20 phút)"
rds wait db-instance-available --db-instance-identifier "$NEW"
RTO=$(( $(date +%s) - T0 ))
NEW_HOST=$(rds describe-db-instances --db-instance-identifier "$NEW" --query 'DBInstances[0].Endpoint.Address' --output text)
echo "✓ $NEW available sau ${RTO}s — $NEW_HOST"

# ── 6. Đọc giá đúng từ bản khôi phục ─────────────────────────────────────────
log "6. Giá trên bản khôi phục (phải trùng ảnh chụp bước 2)"
RESTORED=$(echo "$QUERY" | psql_in "$NEW_HOST")
echo "$RESTORED"
[ "$RESTORED" = "$BASELINE" ] || die "bản khôi phục KHÁC ảnh chụp trước sự cố — dừng, không sửa gì"
echo "✓ khớp từng dòng ($N gói)"

# ── 7. Sửa đúng chỗ hỏng trên DB đang chạy ───────────────────────────────────
log "7. Sửa giá trên DB đang chạy — CHỈ cột price_amount, trong 1 transaction"
REPAIR=$( { echo "BEGIN;"; echo "$RESTORED" | awk -F'|' '{printf "UPDATE product_offering SET price_amount = %s WHERE id = %c%s%c;\n", $3, 39, $1, 39}'; echo "COMMIT;"; } )
echo "$REPAIR" | head -4; echo "   …"
echo "$REPAIR" | psql_in >/dev/null
AFTER=$(echo "$QUERY" | psql_in)
[ "$AFTER" = "$BASELINE" ] || die "sau khi sửa vẫn lệch ảnh chụp"
echo "✓ DB đang chạy đã về đúng giá"
if [ -n "$ALB" ]; then
  curl -fsS "http://$ALB/api/tmf-api/productCatalog/v4/productOffering?limit=3" | jq -c '[.[] | {name, priceAmount}]' || true
fi

# ── 8. Dọn ──────────────────────────────────────────────────────────────────
if [ "${KEEP:-0}" = 1 ]; then
  log "8. KEEP=1 — GIỮ $NEW. Nhớ xóa: aws rds delete-db-instance --db-instance-identifier $NEW --skip-final-snapshot --delete-automated-backups"
else
  log "8. Xóa $NEW"
  rds delete-db-instance --db-instance-identifier "$NEW" --skip-final-snapshot --delete-automated-backups >/dev/null
  rds wait db-instance-deleted --db-instance-identifier "$NEW"
  echo "✓ đã xóa $NEW"
fi

log "KẾT QUẢ: sự cố lúc $T_ACCIDENT, khôi phục về $T_GOOD, instance mới sẵn sàng sau ${RTO}s; $N gói về đúng giá."
