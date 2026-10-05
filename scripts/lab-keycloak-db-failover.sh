#!/usr/bin/env bash
# Lab (issue #217): Keycloak có tự hồi phục khi DB primary BIẾN MẤT IM LẶNG rồi DNS trỏ sang primary mới không?
# Tái hiện trên máy bằng Docker đúng cơ chế đã thấy ở Lab 10 (mất 1 AZ trên prod) — $0, ~5 phút:
#
#   pg1 (alias DNS "db") ── Keycloak (image apps/identity/keycloak, start --optimized, jdbc-ping)
#   pg2 (chưa có alias)
#
#   1. Keycloak khởi động trên pg1, chờ /health/ready = 200, chạy thêm WARMUP giây (để JDBC_PING2 mượn/trả
#      kết nối vài vòng — đó là lúc network timeout của kết nối trong pool bị đặt lại, xem "Nguyên nhân").
#   2. Chép dữ liệu pg1 → pg2 (pg_dump | psql) — pg2 đóng vai standby được promote.
#   3. "Mất AZ": iptables DROP mọi gói từ Keycloak tới IP của pg1 (mất hút, không RST — như NACL deny-all);
#      "RDS failover": gỡ pg1 khỏi mạng (mất alias) và gắn alias "db" cho pg2.
#   4. Gọi /health/ready mỗi 2 s, đo bao lâu thì Ready lại (tối đa LIMIT giây).
#
# Usage:
#   ./scripts/lab-keycloak-db-failover.sh                       # 2 giá trị timeout đọc TỪ manifest keycloak-aws
#   NETWORK_TIMEOUT= ./scripts/lab-keycloak-db-failover.sh      # bỏ bản sửa → tái hiện lỗi #217 (exit 1)
# CI (ci-keycloak.yml) chạy dạng đầu với image vừa build → xóa/sai env trong manifest, hoặc bản Keycloak mới
# làm property hết tác dụng, là PR đỏ.
#   IMAGE=bss/keycloak:local LIMIT=300 WARMUP=60 ./scripts/lab-keycloak-db-failover.sh
#
# Nguyên nhân (#217): Keycloak ≥ 26.8.0 gọi connection.setNetworkTimeout(...) trên mỗi kết nối JDBC_PING2 mượn từ
# pool (keycloak/keycloak#51916). Khi trả kết nối, Agroal đặt lại network timeout theo cấu hình CỦA AGROAL
# (quarkus.datasource.jdbc.network-timeout — mặc định 0 = vô hạn), xóa mất `socketTimeout` mà pgjdbc đặt từ JDBC
# URL. Health check DB sau đó đọc trên một kết nối không timeout tới primary đã chết → treo tới khi kernel bỏ
# socket (~16 phút). Sửa: đặt network-timeout của Agroal bằng đúng socketTimeout.
set -euo pipefail

IMAGE="${IMAGE:-bss/keycloak:lab}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEPLOY="$ROOT/infrastructure/kubernetes/components/keycloak-aws/deployment.yaml"
# Đọc đúng giá trị sẽ được deploy: dòng `- { name: X, value: "…" }` trong manifest.
manifest_env() { sed -n "s/^ *- { name: $1, value: \"\(.*\)\" }.*/\1/p" "$DEPLOY" | tr -d '\r' | head -1; }
# Biến KHÔNG được truyền vào → lấy từ manifest, và thiếu trong manifest là lỗi (đừng lặng lẽ chạy sai cấu hình —
# bản đầu của script này đã làm đúng như thế vì một dòng sed hỏng). Truyền rỗng (NETWORK_TIMEOUT=) = cố ý bỏ.
if [ -z "${DB_URL_PROPERTIES+x}" ]; then
  DB_URL_PROPERTIES="$(manifest_env KC_DB_URL_PROPERTIES)"
  [ -n "$DB_URL_PROPERTIES" ] || { echo "✗ $DEPLOY không có KC_DB_URL_PROPERTIES (socketTimeout…)" >&2; exit 1; }
fi
if [ -z "${NETWORK_TIMEOUT+x}" ]; then
  NETWORK_TIMEOUT="$(manifest_env QUARKUS_DATASOURCE_JDBC_NETWORK_TIMEOUT)"
  [ -n "$NETWORK_TIMEOUT" ] || { echo "✗ $DEPLOY không có QUARKUS_DATASOURCE_JDBC_NETWORK_TIMEOUT — chính là lỗi #217" >&2; exit 1; }
fi
LIMIT="${LIMIT:-300}"
WARMUP="${WARMUP:-60}"
P="kcfo"   # tiền tố tên container/mạng của lab
KC_ENV=(
  -e KC_DB_URL_HOST=db -e KC_DB_URL_PORT=5432 -e KC_DB_URL_DATABASE=keycloak
  -e KC_DB_USERNAME=kc -e KC_DB_PASSWORD=kc-lab-only
  -e "KC_DB_URL_PROPERTIES=$DB_URL_PROPERTIES"
  -e KC_HOSTNAME=http://localhost:8080/auth -e KC_HTTP_ENABLED=true
  -e KC_BOOTSTRAP_ADMIN_USERNAME=admin -e "KC_BOOTSTRAP_ADMIN_PASSWORD=lab-$RANDOM$RANDOM"
)
[ -z "$NETWORK_TIMEOUT" ] || KC_ENV+=(-e "QUARKUS_DATASOURCE_JDBC_NETWORK_TIMEOUT=$NETWORK_TIMEOUT")
for kv in ${KC_EXTRA_ENV:-}; do KC_ENV+=(-e "$kv"); done   # KC_EXTRA_ENV="A=1 B=2" — thêm env tùy ý

log() { echo "[$(date +%H:%M:%S)] $*"; }
cleanup() {
  docker rm -f "$P-probe" "$P-kc" "$P-pg1" "$P-pg2" >/dev/null 2>&1 || true
  docker network rm "$P" >/dev/null 2>&1 || true
}
trap '[ -n "${KEEP:-}" ] || cleanup' EXIT   # KEEP=1: giữ container lại để soi (thread dump, show-config)
cleanup

log "image $IMAGE · KC_DB_URL_PROPERTIES='$DB_URL_PROPERTIES' · network-timeout='${NETWORK_TIMEOUT:-(không đặt)}'"
docker image inspect "$IMAGE" >/dev/null 2>&1 || { log "build $IMAGE từ apps/identity/keycloak"; docker build -q -t "$IMAGE" "$ROOT/apps/identity/keycloak" >/dev/null; }
# IP TĨNH cho 2 Postgres: nếu để Docker tự cấp, pg2 gắn lại sau khi pg1 rời mạng sẽ nhận ĐÚNG IP cũ của pg1 —
# IP đang bị iptables DROP — và "primary mới" cũng mất hút (lỗi thật của bản lab đầu, làm 2 lần đo vô nghĩa).
SUBNET="${SUBNET:-172.31.217}"; PG1_IP="$SUBNET.10"; PG2_IP="$SUBNET.11"
docker network create --subnet "$SUBNET.0/24" "$P" >/dev/null
PG_ENV=(-e POSTGRES_USER=kc -e POSTGRES_PASSWORD=kc-lab-only -e POSTGRES_DB=keycloak)
docker run -d --name "$P-pg1" --network "$P" --ip "$PG1_IP" --network-alias db "${PG_ENV[@]}" postgres:16-alpine >/dev/null
docker run -d --name "$P-pg2" --network "$P" --ip "$PG2_IP" "${PG_ENV[@]}" postgres:16-alpine >/dev/null
for c in pg1 pg2; do until docker exec "$P-$c" pg_isready -U kc -d keycloak -q; do sleep 1; done; done
sleep 2   # entrypoint của postgres khởi động lại 1 lần sau initdb

docker run -d --name "$P-kc" --network "$P" "${KC_ENV[@]}" "$IMAGE" start --optimized >/dev/null
# Đầu dò chạy CHUNG network namespace với Keycloak (cổng quản trị 9000 không cần publish ra máy).
docker run -d --name "$P-probe" --network "container:$P-kc" curlimages/curl:latest sh -c \
  'while :; do echo "$(date +%s) $(curl -s -o /dev/null --max-time 3 -w "%{http_code}" http://127.0.0.1:9000/health/ready)"; sleep 2; done' >/dev/null
ready() { [ "$(docker logs --tail 1 "$P-probe" 2>/dev/null | awk '{print $2}')" = 200 ]; }

log "chờ Keycloak Ready trên pg1…"
for _ in $(seq 1 120); do ready && break; sleep 2; done
ready || { docker logs --tail 30 "$P-kc"; echo "✗ Keycloak không Ready trên pg1" >&2; exit 1; }
log "Ready. Chạy thêm ${WARMUP}s cho JDBC_PING2 mượn/trả kết nối vài vòng…"
sleep "$WARMUP"

log "chép dữ liệu pg1 → pg2 (standby sắp được promote)"
docker exec "$P-pg1" pg_dump -U kc keycloak | docker exec -i "$P-pg2" psql -q -U kc -d keycloak >/dev/null

docker run --rm --network "container:$P-kc" --cap-add NET_ADMIN alpine:3 sh -c \
  "apk add -q --no-cache iptables >/dev/null 2>&1 && iptables -A OUTPUT -d $PG1_IP -j DROP"
docker network disconnect "$P" "$P-pg1"
docker network disconnect "$P" "$P-pg2" && docker network connect --ip "$PG2_IP" --alias db "$P" "$P-pg2"
T0=$(date +%s)
log "💥 pg1 ($PG1_IP) mất hút với Keycloak; DNS 'db' → pg2 ($PG2_IP) (t=0)"

RECOVERED=""
while [ $(( $(date +%s) - T0 )) -lt "$LIMIT" ]; do
  sleep 4
  # Ready lại = 3 lần liên tiếp 200 SAU t=0
  if docker logs "$P-probe" 2>/dev/null | awk -v t0="$T0" '$1>t0' | tail -3 | awk '$2!=200{bad=1} END{exit (NR==3 && !bad)?0:1}'; then
    # …và đã từng có ít nhất 1 lần không-200 sau t=0, hoặc đã qua 40 s (không hề rớt)
    if docker logs "$P-probe" 2>/dev/null | awk -v t0="$T0" '$1>t0 && $2!=200{f=1} END{exit f?0:1}' || [ $(( $(date +%s) - T0 )) -ge 40 ]; then
      RECOVERED=$(docker logs "$P-probe" 2>/dev/null | awk -v t0="$T0" '$1>t0 && $2!=200{last=$1} END{print (last?last-t0:0)}')
      break
    fi
  fi
done

echo ""
echo "══ Kết quả — image $IMAGE, network-timeout='${NETWORK_TIMEOUT:-(không đặt)}', LIMIT=${LIMIT}s ══"
docker logs "$P-probe" 2>/dev/null | awk -v t0="$T0" '$1>t0{n++; c[$2]++} END{printf "đầu dò sau t=0: %d lần —", n; for (k in c) printf " %s×%d", k, c[k]; print ""}'
# grep -c trả exit 1 khi đếm ra 0 — đúng trường hợp TỐT; với pipefail phải nuốt mã đó (lỗi thật của bản đầu).
echo "dòng log \"No executor queue space remaining\": $(docker logs "$P-kc" 2>&1 | grep -c "No executor queue space remaining" || true)"
if [ -n "$RECOVERED" ]; then
  echo "✓ /health/ready về 200 ổn định; lần không-200 cuối ở t=${RECOVERED}s"
else
  echo "✗ sau ${LIMIT}s /health/ready VẪN chưa về 200 ổn định (lỗi #217: chờ timeout TCP của kernel ~16 phút)"
  exit 1
fi
