// dev-threshold.js — Giai đoạn 8, việc 1: tìm ngưỡng req/s trước khi p95 > 500ms trên DEV EKS thật.
//
// Khác `plans-and-order.js` (Giai đoạn 2, mục tiêu: xem HPA có scale không, chạy trên kind 1 node):
// script này tăng tải THEO BẬC (5 bậc rps cố định, không phải VU cố định) để đọc ra CHÍNH XÁC bậc
// nào là nơi p95 vượt 500ms — trả lời thẳng câu hỏi slide 10c của đồ án bằng số thật đo trên hạ
// tầng thật (ALB + EKS dev + RDS thật), không phải suy đoán từ kind.
//
// Vì sao dùng `ramping-arrival-rate` (open model) thay vì `ramping-vus` (closed model, dùng ở
// plans-and-order.js): closed model tự giảm số request/s khi service chậm đi (VU nào cũng phải
// đợi response trước khi bắn request tiếp) — che mất đúng hiện tượng ta muốn đo. Open model giữ
// đúng rps mục tiêu bất kể service phản hồi nhanh hay chậm, giống traffic thật từ nhiều người dùng
// độc lập.
//
// Chạy (cần dev EKS đang bật thật — xem docs/labs/07-load-test-dev.md):
//   BASE_URL=http://<alb-dns-name> k6 run tests/load/dev-threshold.js
//   BASE_URL=... k6 run --summary-export=results/dev-threshold.json tests/load/dev-threshold.js

import http from "k6/http";
import { check } from "k6";
import { Counter } from "k6/metrics";

const BASE_URL = __ENV.BASE_URL || "http://localhost:8080";

// Mặc định: 5 bậc rps cố định (10→150), mỗi bậc giữ 90s, tổng ~10 phút. Bậc khác (vd. lần đo 200→700 của GĐ8
// và ADR-010, trước đây là "script tạm không commit" nên không ai chạy lại được) truyền qua biến môi trường:
//   STAGES=200,325,450,575,700 BASE_URL=http://<alb> k6 run tests/load/dev-threshold.js
const STAGES = (__ENV.STAGES || "10,25,50,100,150").split(",").map((s) => parseInt(s, 10));
const MAX_VUS = parseInt(__ENV.MAX_VUS || "300", 10);

// Đếm request theo MÃ HTTP (2026-10-01): "7,9% lỗi" của ADR-010 không cho biết lỗi LÀ GÌ — 502 (gateway/ALB
// gặp đích chết), 503 (circuit breaker / không có target khỏe), 504 (timeout phía ALB) hay 0 (k6 tự timeout /
// kết nối bị cắt) chỉ về các nguyên nhân khác nhau. Ngưỡng "count>=0" luôn đạt — chỉ để summary in từng mã.
const statusCodes = new Counter("status_codes");
const TRACKED = ["0", "200", "403", "429", "500", "502", "503", "504"];

export const options = {
  scenarios: {
    find_threshold: {
      executor: "ramping-arrival-rate",
      startRate: STAGES[0],
      timeUnit: "1s",
      preAllocatedVUs: 50,
      maxVUs: MAX_VUS,
      stages: [
        { target: STAGES[0], duration: "30s" }, // baseline
        ...STAGES.map((target) => ({ target, duration: "90s" })),
        { target: 0, duration: "30s" }, // cooldown, quan sát HPA scale-down
      ],
    },
  },
  thresholds: {
    // KHÔNG dùng để làm k6 "pass/fail" toàn bài — mục tiêu là ĐỌC p95 theo từng bậc trong summary,
    // không phải chặn ngay khi vượt 500ms một lần (traffic thật cũng có outlier).
    http_req_duration: ["p(95)<500"],
    ...Object.fromEntries(TRACKED.map((s) => [`status_codes{status:${s}}`, ["count>=0"]])),
  },
};

export default function () {
  const res = http.get(
    `${BASE_URL}/api/tmf-api/productCatalog/v4/productOffering`
  );
  statusCodes.add(1, { status: String(res.status) });
  check(res, {
    "status is 200": (r) => r.status === 200,
    "body is non-empty array": (r) => {
      try {
        return JSON.parse(r.body).length > 0;
      } catch {
        return false;
      }
    },
  });
}
