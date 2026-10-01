// k6 load test — Giai đoạn 2 checkpoint cuối: "k6 ở 50 VU → HPA tăng pod; dừng tải → giảm sau
// ~5 phút" (learning/20). Chạy qua Ingress thật (http://bss.localhost), cùng luồng nghiệp vụ với
// scripts/e2e-kind.sh (xem gói → đặt hàng) nhưng lặp liên tục với nhiều "người dùng ảo" (VU).
//
// 2026-09-30: viết lại cho auth LUÔN bật (ADR-008). Bản cũ tạo khách bằng `POST /customer` không token
// và đặt hàng với `customerId` trong body — từ GĐ9 mọi request ghi đó là 401, tức phần "đặt hàng" của
// bài tải đã âm thầm hỏng (chỉ còn đường đọc gói là thật). Giờ mỗi khách ảo là 1 USER KEYCLOAK THẬT:
//   setup(): tạo N user (Admin REST API) → mỗi user tự tạo hồ sơ (/customer/me) → admin1 duyệt (Active)
//   mỗi VU:  xem gói → đặt hàng bằng token của 1 trong N khách; gia hạn bằng refresh_token trước khi token
//            5 phút hết hạn (setup đăng nhập bằng mật khẩu đúng 1 lần/khách — client `api-gateway`, chỉ cho test).
//
// Usage (kind — user thử admin1/admin1pass chỉ có ở local):
//   KC_ADMIN_PASSWORD=$(kubectl --context kind-bss -n bss get secret keycloak-admin -o jsonpath='{.data.password}' | base64 -d) \
//     k6 run -e KC_ADMIN_PASSWORD="$KC_ADMIN_PASSWORD" tests/load/plans-and-order.js
//   Biến tuỳ chọn: BASE_URL (mặc định http://bss.localhost), USERS (số khách ảo, mặc định 10),
//   ADMIN_USER/ADMIN_PASS (người duyệt, mặc định admin1/admin1pass), VUS (đỉnh tải, mặc định 50),
//   HOLD (thời gian giữ đỉnh, mặc định 3m).
//
// Trong lúc chạy, ở terminal khác:
//   kubectl -n bss get hpa -w                 # xem cột REPLICAS tăng dần
//   kubectl -n bss get pods -w                # xem Pod mới được tạo
//
// Sau khi script dừng, HPA cần thêm ~5 phút mới scale-down — đó là
// `behavior.scaleDown.stabilizationWindowSeconds: 300` cố ý đặt trong mọi hpa.yaml (chống dao động).
import http from 'k6/http';
import { check, fail, sleep } from 'k6';

const BASE_URL = __ENV.BASE_URL || 'http://bss.localhost';
const HOST = BASE_URL.replace(/^https?:\/\//, '').split(/[:/]/)[0];
const API = `${BASE_URL}/api`;
const REALM = `${BASE_URL}/auth/realms/bss/protocol/openid-connect/token`;
const USERS = parseInt(__ENV.USERS || '10', 10);
const VUS = parseInt(__ENV.VUS || '50', 10);
const JSON_HEADERS = { 'Content-Type': 'application/json' };

// Ramp lên VUS rồi giữ — không ramp-down trong script vì mục đích là *dừng tải đột ngột* rồi quan sát
// HPA tự hạ dần (giống một đợt traffic bất ngờ kết thúc thật).
export const options = {
  stages: [
    { duration: '1m', target: Math.ceil(VUS * 0.4) },
    { duration: '1m', target: VUS },
    { duration: __ENV.HOLD || '3m', target: VUS }, // giữ đủ lâu để HPA (poll ~15s) kịp phản ứng
  ],
  thresholds: {
    // Không làm fail cứng phần độ trễ — mục đích là QUAN SÁT HPA (learning/13 mục 4). Nhưng request
    // lỗi thì PHẢI làm run đỏ: bản cũ "xanh" trong khi mọi lệnh đặt hàng đều 401 (xem đầu file).
    http_req_duration: ['p(95)<2000'],
    'checks{kind:order}': ['rate>0.99'],
    // Gia hạn token hỏng → VU BỎ QUA lệnh đặt hàng (không có request nào để đếm) → ngưỡng order ở trên
    // không thấy. Phải có ngưỡng riêng, nếu không lỗi auth lại "xanh giả" y như bản cũ.
    'checks{kind:login}': ['rate>0.99'],
  },
  setupTimeout: '3m',
  // Trình duyệt tự hiểu *.localhost = 127.0.0.1, nhưng resolver của k6 (Go) trên Windows thì không
  // ("lookup bss.localhost: no such host" — gặp thật 2026-09-30) → khai tường minh.
  hosts: /\.localhost$/.test(HOST) ? { [HOST]: '127.0.0.1' } : {},
};

function passwordLogin(username, password) {
  const res = http.post(REALM, { grant_type: 'password', client_id: 'api-gateway', username, password });
  if (res.status !== 200) fail(`không lấy được token cho ${username}: HTTP ${res.status} ${res.body}`);
  return res.json();
}

function passwordToken(username, password) {
  return passwordLogin(username, password).access_token;
}

// setup() chạy đúng 1 lần trước mọi VU — tạo sẵn USERS khách ĐÃ DUYỆT, tránh mỗi VU tự tạo user (làm
// Keycloak + bảng customer phình to vô ích qua nhiều lần chạy).
export function setup() {
  const kcPass = __ENV.KC_ADMIN_PASSWORD;
  if (!kcPass) fail('cần -e KC_ADMIN_PASSWORD=<mật khẩu admin master realm> (xem Usage đầu file)');
  const masterRes = http.post(`${BASE_URL}/auth/realms/master/protocol/openid-connect/token`, {
    grant_type: 'password', client_id: 'admin-cli', username: __ENV.KC_ADMIN_USER || 'admin', password: kcPass,
  });
  if (masterRes.status !== 200) fail(`không đăng nhập được Keycloak master: HTTP ${masterRes.status}`);
  const kcAdmin = { headers: { ...JSON_HEADERS, Authorization: `Bearer ${masterRes.json('access_token')}` } };
  const approver = {
    headers: {
      'Content-Type': 'application/merge-patch+json',
      Authorization: `Bearer ${passwordToken(__ENV.ADMIN_USER || 'admin1', __ENV.ADMIN_PASS || 'admin1pass')}`,
    },
  };

  const run = Date.now();
  const users = [];
  for (let i = 0; i < USERS; i++) {
    const username = `k6-load-${run}-${i}`;
    const password = `k6-${run}-${i}-pw`;
    const created = http.post(`${BASE_URL}/auth/admin/realms/bss/users`, JSON.stringify({
      username, email: `${username}@example.com`, firstName: 'k6', lastName: `load ${i}`,
      enabled: true, emailVerified: true, credentials: [{ type: 'password', value: password, temporary: false }],
    }), kcAdmin);
    check(created, { 'setup: keycloak user created': (r) => r.status === 201 });

    // Đăng nhập bằng MẬT KHẨU đúng 1 lần/user ở đây. Password grant bắt Keycloak băm mật khẩu (rất tốn CPU):
    // bản đầu để 50 VU tự đăng nhập bằng mật khẩu cùng lúc → Keycloak (1 CPU trên kind) nghẽn, token request
    // timeout 60 s, 2% đơn hàng hỏng (đo thật 2026-09-30). VU chỉ gia hạn bằng refresh_token (không băm).
    const login = passwordLogin(username, password);
    const me = { headers: { ...JSON_HEADERS, Authorization: `Bearer ${login.access_token}` } };
    const profile = http.post(`${API}/tmf-api/customerManagement/v4/customer/me`,
      JSON.stringify({ name: `k6 load ${i}` }), me);
    check(profile, { 'setup: profile created': (r) => r.status === 201 });
    const approved = http.patch(`${API}/tmf-api/customerManagement/v4/customer/${profile.json('id')}`,
      JSON.stringify({ status: 'Active' }), approver);
    check(approved, { 'setup: approved by admin': (r) => r.status === 200 });
    users.push({ username, refreshToken: login.refresh_token });
  }

  const offeringsRes = http.get(`${API}/tmf-api/productCatalog/v4/productOffering?lifecycleStatus=Active&limit=10`);
  check(offeringsRes, { 'setup: offerings found': (r) => r.status === 200 && r.json().length > 0 });
  return { users, offeringIds: offeringsRes.json().map((o) => o.id) };
}

// Token của VU này — biến cấp module là RIÊNG cho từng VU trong k6. Gia hạn bằng refresh_token khi còn
// < 60 s (token realm mặc định sống 300 s, còn bài test chạy ~5 phút). Lỗi → trả null, lần sau thử lại
// (bản đầu gọi res.json() trên response rỗng khi timeout → cả iteration crash).
let session = null;

function tokenFor(data) {
  const now = Date.now();
  if (!session || session.expiresAt - now < 60_000) {
    const user = data.users[(__VU - 1) % data.users.length];
    const res = http.post(REALM, { grant_type: 'refresh_token', client_id: 'api-gateway',
      refresh_token: session ? session.refreshToken : user.refreshToken }, { tags: { kind: 'login' } });
    const ok = check(res, { 'token refresh: 200': (r) => r.status === 200 }, { kind: 'login' });
    if (!ok) return null;
    const body = res.json();
    session = { token: body.access_token, refreshToken: body.refresh_token, expiresAt: now + body.expires_in * 1000 };
  }
  return session.token;
}

export default function (data) {
  const offeringId = data.offeringIds[Math.floor(Math.random() * data.offeringIds.length)];

  // Đọc gói (công khai — chạm gateway + product-catalog)
  const listRes = http.get(`${API}/tmf-api/productCatalog/v4/productOffering?limit=10`, { tags: { kind: 'list' } });
  check(listRes, { 'list offerings: 200': (r) => r.status === 200 }, { kind: 'list' });

  // Đặt hàng bằng token của chính khách (đường ghi — gateway → order-management → customer-service
  // (/me) + product-catalog (giá, B-13) → outbox → LocalStack → billing-service). Không gửi customerId.
  const token = tokenFor(data);
  if (!token) { sleep(1); return; }
  const orderRes = http.post(`${API}/tmf-api/orderManagement/v4/productOrder`,
    JSON.stringify({ category: 'new', description: 'k6 load test', items: [{ productOfferingId: offeringId, quantity: 1 }] }),
    { headers: { ...JSON_HEADERS, Authorization: `Bearer ${token}` }, tags: { kind: 'order' } });
  check(orderRes, { 'create order: 201': (r) => r.status === 201 }, { kind: 'order' });

  sleep(1); // ~1 request ghi/giây/VU
}
