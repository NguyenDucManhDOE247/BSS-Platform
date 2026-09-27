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

const BASE_URL = __ENV.BASE_URL || "http://localhost:8080";

// 5 bậc rps cố định, mỗi bậc giữ 90s (đủ để p95 ổn định + HPA có thời gian phản ứng), tổng ~10 phút.
// Chỉnh lại các mốc này theo kết quả bậc đầu nếu hệ thống bão hòa sớm/muộn hơn dự kiến.
export const options = {
  scenarios: {
    find_threshold: {
      executor: "ramping-arrival-rate",
      startRate: 10,
      timeUnit: "1s",
      preAllocatedVUs: 50,
      maxVUs: 300,
      stages: [
        { target: 10, duration: "30s" }, // baseline
        { target: 10, duration: "90s" },
        { target: 25, duration: "90s" },
        { target: 50, duration: "90s" },
        { target: 100, duration: "90s" },
        { target: 150, duration: "90s" },
        { target: 0, duration: "30s" }, // cooldown, quan sát HPA scale-down
      ],
    },
  },
  thresholds: {
    // KHÔNG dùng để làm k6 "pass/fail" toàn bài — mục tiêu là ĐỌC p95 theo từng bậc trong summary,
    // không phải chặn ngay khi vượt 500ms một lần (traffic thật cũng có outlier).
    http_req_duration: ["p(95)<500"],
  },
};

export default function () {
  const res = http.get(
    `${BASE_URL}/api/tmf-api/productCatalog/v4/productOffering`
  );
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
