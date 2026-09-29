#!/usr/bin/env bash
# Test hồi quy cho B-52: scripts/smoke.sh PHẢI thất bại khi endpoint hỏng.
#
#   ./scripts/tests/smoke.test.sh
#
# Dựng một "gateway giả" bằng Python http.server (kịch bản chọn bằng biến FAKE_MODE) rồi chạy
# smoke.sh với SMOKE_BASE_URL trỏ vào đó — không cần AWS, không cần cluster.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SMOKE="$HERE/../smoke.sh"
WORK="$(mktemp -d)"
SERVER_PID=""
stop_server() { [ -z "$SERVER_PID" ] || { kill "$SERVER_PID" 2>/dev/null; wait "$SERVER_PID" 2>/dev/null; SERVER_PID=""; }; }
trap 'stop_server; rm -rf "$WORK"' EXIT

# Chọn Python THẬT: trên Windows `python3` thường là stub của Microsoft Store (in lời nhắc cài đặt
# rồi exit ≠ 0) nên `command -v` không đủ — phải chạy thử một lệnh.
PY=""
for c in python3 python py; do
  if command -v "$c" >/dev/null 2>&1 && "$c" -c 'import http.server' >/dev/null 2>&1; then PY="$c"; break; fi
done
[ -n "$PY" ] || { echo "cần Python 3 chạy được (python3/python/py) để dựng gateway giả"; exit 1; }

cat > "$WORK/fake_gateway.py" <<'PYEOF'
import http.server, json, os, sys, time

MODE = os.environ["FAKE_MODE"]
START = time.time()

class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a):  # im lặng
        pass

    def send(self, code, body):
        data = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        offering = "productOffering" in self.path
        me = self.path.endswith("/customer/me")
        authed = bool(self.headers.get("Authorization"))
        if MODE in ("ok", "auth-off", "no-role-check") or (MODE == "flaky" and time.time() - START >= 3):
            if offering:
                self.send(200, [{"id": "1"}])
            elif MODE == "auth-off":             # auth bị tắt: API quản trị trả dữ liệu cho người lạ
                self.send(200, [])
            elif not authed:                     # gateway thật: không token → 401, body RỖNG
                self.send_response(401); self.send_header("Content-Length", "0"); self.end_headers()
            elif me:
                self.send(404, {"title": "Not Found", "status": 404})
            elif MODE == "no-role-check":        # token customer mà vẫn liệt kê được mọi khách
                self.send(200, [])
            else:
                self.send_response(403); self.send_header("Content-Length", "0"); self.end_headers()
        elif MODE == "empty-offering":          # 200 nhưng seed data mất → vẫn phải coi là hỏng
            self.send(200, [])
        elif MODE == "500":
            self.send(500, {"title": "boom"})
        elif MODE == "not-json":
            self.send_response(200); self.send_header("Content-Length", "5"); self.end_headers(); self.wfile.write(b"<html")
        elif MODE == "flaky":                    # 503 trong 3 giây đầu (ALB chưa đăng ký target) rồi khoẻ
            self.send(503, {"title": "no healthy upstream"})

srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
open(sys.argv[1], "w").write(str(srv.server_address[1]))
srv.serve_forever()
PYEOF

pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "  ✓ $1"; }
bad() { fail=$((fail + 1)); echo "  ✗ $1"; [ -z "${2:-}" ] || echo "      $2"; }

# run_case "mô tả" MODE mong_đợi_exit [TIMEOUT] [TOKEN] — mặc định có token (như chế độ AWS tự lấy)
run_case() {
  local desc="$1" mode="$2" want="$3" timeout="${4:-2}" token="${5-fake-customer-token}" port out rc
  rm -f "$WORK/port"
  FAKE_MODE="$mode" "$PY" "$WORK/fake_gateway.py" "$WORK/port" &
  SERVER_PID=$!
  for _ in $(seq 1 50); do [ -s "$WORK/port" ] && break; sleep 0.1; done
  # Nếu server không lên, KHÔNG được chạy tiếp: các ca "phải FAIL" sẽ đạt giả (smoke fail vì
  # không kết nối được, không phải vì phát hiện đúng lỗi) — chính là loại test vô nghĩa.
  [ -s "$WORK/port" ] || { echo "  ✗ $desc — gateway giả không khởi động được, huỷ bộ test"; exit 1; }
  port="$(cat "$WORK/port")"
  out="$(SMOKE_BASE_URL="http://127.0.0.1:$port" SMOKE_TOKEN="$token" SMOKE_TIMEOUT_SECONDS="$timeout" SMOKE_INTERVAL_SECONDS=1 "$SMOKE" 2>&1)"; rc=$?
  stop_server
  if [ "$rc" -eq "$want" ]; then ok "$desc (exit $rc)"; else bad "$desc" "mong đợi exit $want, nhận $rc — $(tr '\n' '|' <<<"$out" | cut -c1-300)"; fi
}

echo "── smoke.sh phải fail khi hỏng (B-52) và pass khi khoẻ"
run_case "gateway khoẻ → PASS"                                  ok              0
run_case "HTTP 500 → FAIL (bản cũ nuốt lỗi và exit 0)"          500             1
run_case "200 nhưng productOffering rỗng (mất seed) → FAIL"     empty-offering  1
run_case "200 nhưng body không phải JSON → FAIL"                not-json        1
run_case "auth bị tắt (API quản trị trả 200 không cần token) → FAIL"  auth-off   1
run_case "token customer liệt kê được mọi khách (role không kiểm) → FAIL" no-role-check 1
run_case "không có SMOKE_TOKEN: chỉ kiểm công khai + 401 → PASS" ok     0 2 ""
run_case "503 thoáng qua rồi khoẻ (ALB đăng ký target) → PASS nhờ retry" flaky  0 10
run_case "503 kéo dài hơn timeout → vẫn FAIL"                   flaky           1 1

echo
echo "════════ kết quả: $pass đạt, $fail hỏng ════════"
[ "$fail" -eq 0 ]
