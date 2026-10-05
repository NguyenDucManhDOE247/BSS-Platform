#!/usr/bin/env bash
# Chaos experiment #3: MẤT 1 AVAILABILITY ZONE — làm theo kịch bản "AZ Availability: Power Interruption" của
# AWS Fault Injection Service, bằng AWS CLI thuần (không cần dựng FIS):
#
#   1. Cô lập mạng TOÀN BỘ subnet private của 1 AZ bằng một NACL deny-all (NACL mới tạo không có rule allow nào
#      → chặn mọi gói vào/ra). Node + Pod ở AZ đó mất liên lạc với control plane, với Pod khác, với RDS — giống
#      AZ mất điện. Subnet public (ALB, NAT) KHÔNG bị đụng — xem "Giới hạn" bên dưới.
#   2. Nếu RDS primary nằm đúng AZ đó và instance là Multi-AZ → `reboot-db-instance --force-failover` (AWS tự
#      làm việc này khi mất AZ thật; NACL thì RDS không "thấy" nên phải ép).
#   3. Suốt thí nghiệm, 2 đầu dò gọi mỗi giây qua https://<host> thật (cert thật, `curl --connect-to` như
#      smoke.sh): API catalog (ALB → gateway → product-catalog → RDS) và OIDC discovery (ALB → Keycloak).
#      Mỗi 10 s ghi số node NotReady, Pod Pending, Pod Ready của namespace bss, trạng thái RDS.
#   4. Sau DURATION giây: trả NACL gốc về, chờ RECOVERY giây, in tổng kết (số lỗi, cửa sổ lỗi, thời gian hồi phục).
#
# Usage:
#   ./scripts/chaos-az-outage.sh prod                     # AZ = AZ đang chứa RDS primary (mất AZ "tệ nhất")
#   ./scripts/chaos-az-outage.sh prod ap-southeast-1b     # chỉ định AZ
#   DURATION=420 RECOVERY=240 NO_RDS_FAILOVER=1 ./scripts/chaos-az-outage.sh staging
#   INCLUDE_PUBLIC=1 ./scripts/chaos-az-outage.sh prod ap-southeast-1a   # mất CẢ subnet public: node ALB + NAT của AZ đó
#
# Biến: DURATION (mặc định 420 s — dài hơn 300 s `tolerationSeconds` mặc định cho node unreachable, để thấy
# Pod bị đuổi và lên lịch lại), RECOVERY (240 s), BASELINE (60 s), NO_RDS_FAILOVER=1 (bỏ bước 2),
# OUT_DIR (mặc định results/az-outage-<env>-<thời điểm>, đã .gitignore), INCLUDE_PUBLIC=1 (chặn thêm subnet public
# của AZ — chỉ có nghĩa khi mỗi AZ có NAT riêng, `nat_gateway_per_az`; với 1 NAT mà chặn đúng AZ chứa nó thì mọi Pod
# mất đường ra AWS API: đó chính là điểm chết đơn mà ADR-013 gỡ).
#
# An toàn: `trap … EXIT` LUÔN trả từng subnet về NACL cũ rồi xóa NACL thí nghiệm — kể cả khi Ctrl-C hay lỗi
# giữa chừng. Nếu máy tắt đột ngột: `aws ec2 describe-network-acls --filters Name=tag:Purpose,Values=chaos-az-outage`
# rồi `replace-network-acl-association` về NACL mặc định của VPC (lệnh in sẵn ở đầu thí nghiệm).
#
# Mặc định KHÔNG chặn subnet public (đo phần compute + DB — 2 lần chạy đầu của Lab 10). INCLUDE_PUBLIC=1 chặn cả
# subnet public: mất luôn node ALB và NAT Gateway của AZ đó, như mất AZ thật (lần chạy 3, sau ADR-013).
set -euo pipefail

ENV="${1:?Usage: $0 <dev|staging|prod> [az]}"
TARGET_AZ="${2:-}"
REGION="${AWS_REGION:-ap-southeast-1}"
CLUSTER="bss-$ENV-eks"
DB_ID="bss-$ENV-pg"
DURATION="${DURATION:-420}"
RECOVERY="${RECOVERY:-240}"
BASELINE="${BASELINE:-60}"
OUT_DIR="${OUT_DIR:-results/az-outage-$ENV-$(date +%Y%m%d-%H%M%S)}"

log()  { echo "[$(date +%H:%M:%S)] $*"; }
fail() { echo "✗ FAIL: $*" >&2; exit 1; }
awsq() { aws --region "$REGION" "$@" | tr -d '\r'; }   # aws.exe / jq.exe trên Git Bash xuất CRLF (lỗi thật #211)
jqr()  { jq -r "$@" | tr -d '\r'; }

command -v jq >/dev/null 2>&1 || fail "cần jq"
mkdir -p "$OUT_DIR"

# ── Preflight ───────────────────────────────────────────────────────────────────────────────────────
awsq eks describe-cluster --name "$CLUSTER" --query cluster.status --output text | grep -qx ACTIVE \
  || fail "cluster $CLUSTER không ACTIVE"
aws eks update-kubeconfig --region "$REGION" --name "$CLUSTER" >/dev/null
KCTX="$(kubectl config current-context)"
k() { kubectl --context "$KCTX" "$@"; }

VPC_ID="$(awsq eks describe-cluster --name "$CLUSTER" --query cluster.resourcesVpcConfig.vpcId --output text)"
ALB="$(k -n bss get ingress bss-ingress -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')"
HOST="$(k -n bss get ingress bss-ingress -o jsonpath='{.spec.rules[0].host}')"
[ -n "$ALB" ] && [ -n "$HOST" ] || fail "Ingress chưa có ALB/host — CD đã deploy $ENV chưa?"

DB_JSON="$(awsq rds describe-db-instances --db-instance-identifier "$DB_ID" \
  --query 'DBInstances[0].{az:AvailabilityZone,az2:SecondaryAvailabilityZone,multi:MultiAZ,status:DBInstanceStatus}' --output json)"
DB_AZ="$(echo "$DB_JSON" | jqr .az)"; DB_AZ2="$(echo "$DB_JSON" | jqr '.az2 // empty')"
DB_MULTI="$(echo "$DB_JSON" | jqr .multi)"
[ -n "$TARGET_AZ" ] || TARGET_AZ="$DB_AZ"

log "Cluster $CLUSTER · VPC $VPC_ID · host $HOST"
log "RDS $DB_ID: primary $DB_AZ, standby ${DB_AZ2:-—}, MultiAZ=$DB_MULTI · AZ bị cô lập: $TARGET_AZ"
echo "== Node theo AZ trước thí nghiệm =="
k get nodes -L topology.kubernetes.io/zone --no-headers | awk '{print $NF}' | sort | uniq -c
echo "== Pod bss theo AZ (qua node) =="
k -n bss get pods -o wide --no-headers | awk '{print $7}' | while read -r n; do
  k get node "$n" -o jsonpath='{.metadata.labels.topology\.kubernetes\.io/zone}{"\n"}' 2>/dev/null || echo "(chưa xếp node)"; done | sort | uniq -c

mapfile -t SUBNETS < <(awsq ec2 describe-subnets \
  --filters "Name=vpc-id,Values=$VPC_ID" "Name=availability-zone,Values=$TARGET_AZ" "Name=tag:kubernetes.io/role/internal-elb,Values=1" \
  --query 'Subnets[].SubnetId' --output text | tr '\t' '\n' | sed '/^$/d')
[ "${#SUBNETS[@]}" -ge 1 ] || fail "không tìm thấy subnet private nào ở $TARGET_AZ trong $VPC_ID"
if [ -n "${INCLUDE_PUBLIC:-}" ]; then
  mapfile -t PUB < <(awsq ec2 describe-subnets \
    --filters "Name=vpc-id,Values=$VPC_ID" "Name=availability-zone,Values=$TARGET_AZ" "Name=tag:kubernetes.io/role/elb,Values=1" \
    --query 'Subnets[].SubnetId' --output text | tr '\t' '\n' | sed '/^$/d')
  [ "${#PUB[@]}" -ge 1 ] || fail "INCLUDE_PUBLIC=1 nhưng không tìm thấy subnet public ở $TARGET_AZ"
  NATS="$(awsq ec2 describe-nat-gateways --filter "Name=vpc-id,Values=$VPC_ID" "Name=state,Values=available" --query 'length(NatGateways)' --output text)"
  log "INCLUDE_PUBLIC: chặn thêm subnet public ${PUB[*]} (node ALB + NAT của AZ). VPC có $NATS NAT Gateway."
  [ "$NATS" -gt 1 ] || log "⚠ VPC chỉ có 1 NAT — nếu nó nằm ở $TARGET_AZ thì MỌI Pod sẽ mất đường ra AWS API (điểm chết đơn)."
  SUBNETS+=("${PUB[@]}")
fi
log "Subnet sẽ bị cô lập: ${SUBNETS[*]}"

# ── Đầu dò (chạy nền suốt thí nghiệm) ──────────────────────────────────────────────────────────────
PROBE_CSV="$OUT_DIR/probes.csv"; STATE_CSV="$OUT_DIR/cluster-state.csv"
echo "epoch,probe,http_code,seconds" > "$PROBE_CSV"
echo "epoch,nodes_notready,pods_pending,pods_ready,pods_total,rds_status,rds_az" > "$STATE_CSV"
probe_loop() {
  while :; do
    local now; now=$(date +%s)
    for p in "api|/api/tmf-api/productCatalog/v4/productOffering?limit=1" "oidc|/auth/realms/bss/.well-known/openid-configuration"; do
      local name="${p%%|*}" path="${p#*|}" out
      out=$(curl -s -o /dev/null --max-time 5 --connect-to "$HOST:443:$ALB:443" -w '%{http_code},%{time_total}' "https://$HOST$path" || true)
      [ -n "$out" ] || out="000,5"
      echo "$now,$name,$out" >> "$PROBE_CSV"
    done
    sleep 1
  done
}
state_loop() {
  while :; do
    local nr pend ready total rds
    nr=$(k get nodes --no-headers 2>/dev/null | awk '$2 !~ /^Ready/' | wc -l)
    pend=$(k -n bss get pods --field-selector=status.phase=Pending --no-headers 2>/dev/null | wc -l)
    read -r ready total < <(k -n bss get pods --no-headers 2>/dev/null | awk '{split($2,a,"/"); t++; if (a[1]==a[2] && $3=="Running") r++} END {print r+0, t+0}')
    rds=$(awsq rds describe-db-instances --db-instance-identifier "$DB_ID" --query 'DBInstances[0].[DBInstanceStatus,AvailabilityZone]' --output text 2>/dev/null | tr '\t' ',')
    echo "$(date +%s),$nr,$pend,$ready,$total,${rds:-?,?}" >> "$STATE_CSV"
    sleep 10
  done
}

# ── Cô lập / khôi phục ─────────────────────────────────────────────────────────────────────────────
CHAOS_NACL=""; declare -A ORIG_NACL=() NEW_ASSOC=()
restore() {
  local rc=$?
  set +e
  for s in "${!NEW_ASSOC[@]}"; do
    log "↩ trả $s về NACL gốc ${ORIG_NACL[$s]}"
    awsq ec2 replace-network-acl-association --association-id "${NEW_ASSOC[$s]}" --network-acl-id "${ORIG_NACL[$s]}" >/dev/null \
      || echo "⚠ KHÔNG trả được $s — làm tay: aws ec2 replace-network-acl-association --association-id ${NEW_ASSOC[$s]} --network-acl-id ${ORIG_NACL[$s]}" >&2
  done
  NEW_ASSOC=()
  if [ -n "$CHAOS_NACL" ]; then
    awsq ec2 delete-network-acl --network-acl-id "$CHAOS_NACL" >/dev/null && log "đã xóa NACL thí nghiệm $CHAOS_NACL"
    CHAOS_NACL=""
  fi
  jobs -p | xargs -r kill 2>/dev/null
  return $rc
}
trap restore EXIT

log "Baseline ${BASELINE}s (đầu dò + trạng thái chạy nền)…"
probe_loop & state_loop &
sleep "$BASELINE"

CHAOS_NACL="$(awsq ec2 create-network-acl --vpc-id "$VPC_ID" \
  --tag-specifications "ResourceType=network-acl,Tags=[{Key=Name,Value=bss-$ENV-chaos-az-$TARGET_AZ},{Key=Purpose,Value=chaos-az-outage}]" \
  --query NetworkAcl.NetworkAclId --output text)"
log "NACL deny-all: $CHAOS_NACL (không rule allow nào)"
for s in "${SUBNETS[@]}"; do
  read -r assoc orig < <(awsq ec2 describe-network-acls --filters "Name=association.subnet-id,Values=$s" \
    --query "NetworkAcls[0].[Associations[?SubnetId=='$s'].NetworkAclAssociationId | [0], NetworkAclId]" --output text)
  ORIG_NACL[$s]="$orig"
  echo "  khôi phục tay nếu cần: aws ec2 replace-network-acl-association --association-id <id mới> --network-acl-id $orig  # $s"
  NEW_ASSOC[$s]="$(awsq ec2 replace-network-acl-association --association-id "$assoc" --network-acl-id "$CHAOS_NACL" \
    --query NewAssociationId --output text)"
done
T_ISOLATE=$(date +%s)
log "💥 $TARGET_AZ BỊ CÔ LẬP (t=0)"

if [ -z "${NO_RDS_FAILOVER:-}" ] && [ "$DB_AZ" = "$TARGET_AZ" ]; then
  if [ "$DB_MULTI" = "True" ] || [ "$DB_MULTI" = "true" ]; then
    awsq rds reboot-db-instance --db-instance-identifier "$DB_ID" --force-failover >/dev/null
    log "RDS: force-failover $DB_AZ → ${DB_AZ2:-?}"
  else
    log "⚠ RDS primary ở AZ bị cô lập nhưng KHÔNG Multi-AZ — DB sẽ mất tới khi khôi phục (đúng như AZ chết thật)"
  fi
fi

sleep "$DURATION"
log "Khôi phục mạng $TARGET_AZ (t=$(( $(date +%s) - T_ISOLATE ))s)"
for s in "${!NEW_ASSOC[@]}"; do
  awsq ec2 replace-network-acl-association --association-id "${NEW_ASSOC[$s]}" --network-acl-id "${ORIG_NACL[$s]}" >/dev/null
done
NEW_ASSOC=()
awsq ec2 delete-network-acl --network-acl-id "$CHAOS_NACL" >/dev/null; CHAOS_NACL=""
T_RESTORE=$(date +%s)
log "Theo dõi hồi phục ${RECOVERY}s…"
sleep "$RECOVERY"
jobs -p | xargs -r kill 2>/dev/null || true

# ── Tổng kết ───────────────────────────────────────────────────────────────────────────────────────
echo ""
echo "══ Tổng kết — $ENV, cô lập $TARGET_AZ trong $DURATION s (t=0 lúc cô lập, khôi phục ở t=$((T_RESTORE - T_ISOLATE))) ══"
for p in api oidc; do
  awk -F, -v p="$p" -v t0="$T_ISOLATE" 'NR>1 && $2==p {
      n++; ok = ($3 ~ /^[23]/); if (!ok) { f++; if (first=="") first=$1-t0; last=$1-t0 }
      if ($1 < t0) { bn++; if (!ok) bf++ }
    } END {
      printf "%-5s %5d request, %4d lỗi (%.2f%%) · baseline lỗi %d/%d", p, n, f, (n? 100*f/n : 0), bf, bn
      if (f) printf " · lỗi đầu t=%ds, lỗi cuối t=%ds\n", first, last; else printf " · 0 lỗi\n"
    }' "$PROBE_CSV"
done
awk -F, -v t0="$T_ISOLATE" 'NR>1 { if ($2>mnr) mnr=$2; if ($3>mp) mp=$3; if ($2>0 && fnr=="") fnr=$1-t0 }
  END { printf "node NotReady tối đa %d (lần đầu t=%ss) · Pod Pending tối đa %d\n", mnr, (fnr==""?"—":fnr), mp }' "$STATE_CSV"
echo "RDS sau thí nghiệm: $(awsq rds describe-db-instances --db-instance-identifier "$DB_ID" --query 'DBInstances[0].[DBInstanceStatus,AvailabilityZone,SecondaryAvailabilityZone]' --output text)"
echo "Pod bss hiện tại:"; k -n bss get pods -o wide
echo ""
echo "Số liệu thô: $PROBE_CSV, $STATE_CSV — bước tiếp: ./scripts/e2e-flow.sh $ENV (kiểm cả luồng order → SQS → hóa đơn)"
