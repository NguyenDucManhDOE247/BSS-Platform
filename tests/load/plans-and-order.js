// k6 load test — Giai đoạn 2 checkpoint cuối: "k6 ở 50 VU → HPA tăng pod; dừng tải → giảm sau
// ~5 phút" (learning/20 dòng 123). Chạy qua Ingress thật (http://bss.localtest.me), giống hệt
// luồng nghiệp vụ của scripts/e2e-kind.sh (xem offering → đặt hàng) nhưng lặp lại liên tục với
// nhiều "người dùng ảo" (VU) cùng lúc thay vì 1 lần.
//
// Usage:
//   k6 run tests/load/plans-and-order.js
//   k6 run --env BASE_URL=http://bss.localtest.me tests/load/plans-and-order.js   # tuỳ chỉnh host
//
// Trong lúc chạy, ở terminal khác:
//   kubectl -n bss get hpa -w                 # xem cột REPLICAS tăng dần
//   kubectl -n bss get pods -w                # xem Pod mới được tạo
//
// Sau khi script dừng (hết stage cuối), HPA cần thêm ~5 phút mới scale-down — đó là
// `behavior.scaleDown.stabilizationWindowSeconds: 300` cố ý đặt trong mọi hpa.yaml (chống
// "dao động": scale lên rồi xuống liên tục mỗi khi tải nhấp nhô ngắn hạn) — KHÔNG phải script
// hay HPA bị treo, cứ tiếp tục `kubectl get hpa -w` thêm vài phút sau khi k6 đã in xong kết quả.
import http from 'k6/http';
import { check, sleep } from 'k6';

const BASE_URL = __ENV.BASE_URL || 'http://bss.localtest.me';
const API = `${BASE_URL}/api`;

// Ramp lên 50 VU rồi giữ, đúng con số checkpoint yêu cầu — không cần ramp-down trong script vì
// mục đích là *dừng tải đột ngột* rồi quan sát HPA tự hạ dần (giống một đợt traffic bất ngờ kết
// thúc thật, không phải một đợt giảm tải êm ả).
export const options = {
  stages: [
    { duration: '1m', target: 20 },
    { duration: '1m', target: 50 },
    { duration: '3m', target: 50 }, // giữ 50 VU đủ lâu để HPA (poll mỗi ~15s) kịp phản ứng
  ],
  thresholds: {
    // Không làm script fail cứng — mục đích là QUAN SÁT HPA, không phải gate CI. Ngưỡng này chỉ
    // để bạn tự đọc "hệ thống có bắt đầu chậm đi ở 50 VU không", đúng câu hỏi capacity-planning
    // của learning/13 mục 4.
    http_req_duration: ['p(95)<2000'],
  },
};

// setup() chạy đúng 1 lần trước khi bất kỳ VU nào bắt đầu — tạo sẵn khách hàng + đọc danh sách
// gói 1 lần, tránh mỗi VU tự tạo khách hàng riêng (không cần thiết cho mục đích tải, và làm
// bảng customer phình to vô ích qua nhiều lần chạy).
export function setup() {
  const customers = [];
  for (let i = 0; i < 10; i++) {
    const res = http.post(
      `${API}/tmf-api/customerManagement/v4/customer`,
      JSON.stringify({ name: `k6-load-${i}`, email: `k6-load-${Date.now()}-${i}@example.com` }),
      { headers: { 'Content-Type': 'application/json' } },
    );
    check(res, { 'setup: customer created': (r) => r.status === 201 });
    customers.push(res.json('id'));
  }

  const offeringsRes = http.get(`${API}/tmf-api/productCatalog/v4/productOffering?limit=10`);
  check(offeringsRes, { 'setup: offerings found': (r) => r.status === 200 && r.json().length > 0 });
  const offeringIds = offeringsRes.json().map((o) => o.id);

  return { customers, offeringIds };
}

export default function (data) {
  const customerId = data.customers[Math.floor(Math.random() * data.customers.length)];
  const offeringId = data.offeringIds[Math.floor(Math.random() * data.offeringIds.length)];

  // Đọc gói (đường đọc — chạm product-catalog + gateway)
  const listRes = http.get(`${API}/tmf-api/productCatalog/v4/productOffering?limit=10`);
  check(listRes, { 'list offerings: 200': (r) => r.status === 200 });

  // Đặt hàng (đường ghi — chạm order-management, product-catalog (B-13 tra giá),
  // outbox → LocalStack → billing-service)
  const orderRes = http.post(
    `${API}/tmf-api/orderManagement/v4/productOrder`,
    JSON.stringify({
      customerId,
      category: 'new',
      description: 'k6 load test',
      items: [{ productOfferingId: offeringId, quantity: 1 }],
    }),
    { headers: { 'Content-Type': 'application/json' } },
  );
  check(orderRes, { 'create order: 201': (r) => r.status === 201 });

  sleep(1); // ~1 request/giây/VU — đủ tải để CPU vượt ngưỡng HPA (70%) ở 50 VU mà không dập gãy
}
