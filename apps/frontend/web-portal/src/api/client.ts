import axios, { isAxiosError } from 'axios';
import { currentAccessToken } from '../auth/oidcConfig';

// Vite dev proxy routes /api → api-gateway:8080. In prod the ALB / Ingress does the same.
export const api = axios.create({
  baseURL: '/api',
  headers: { Accept: 'application/json' },
});

/**
 * Giai đoạn 9 (ADR-008): mọi request gắn `Authorization: Bearer <access token>` nếu đã đăng nhập.
 * Duyệt gói cước vẫn gọi được khi chưa đăng nhập (gateway để công khai) — lúc đó không gắn gì.
 *
 * (Trước GĐ9 ở đây là 1 hằng "khách demo" — 1 khách cố định dùng chung cho MỌI người, không tồn tại
 * trong customer-service. Đã xóa hẳn: danh tính giờ đến từ token Keycloak.)
 */
api.interceptors.request.use((config) => {
  const token = currentAccessToken();
  if (token) {
    config.headers.set('Authorization', `Bearer ${token}`);
  }
  return config;
});

/** Lấy câu giải thích của server (ProblemDetail.detail — RFC 7807) để hiển thị cho người dùng. */
export function problemDetail(err: unknown, fallback: string): string {
  if (isAxiosError(err)) {
    const detail: unknown = err.response?.data?.detail;
    if (typeof detail === 'string' && detail.length > 0) return detail;
  }
  return fallback;
}

/**
 * B-15: giá trị cho header `Idempotency-Key` — sinh 1 lần cho mỗi "ý định đặt hàng"; gửi lại cùng key thì
 * order-management trả lại đúng đơn cũ thay vì tạo đơn thứ 2 (bấm đúp, mạng chập chờn).
 *
 * `crypto.randomUUID()` chỉ có trong SECURE CONTEXT (HTTPS hoặc *.localhost) — cùng loại bẫy với PKCE ở
 * GĐ9 (bài 18). Trên AWS hiện chạy HTTP (chưa có domain, B-23) nó là `undefined` → dự phòng bằng
 * `crypto.getRandomValues`, hàm này có ở mọi context.
 */
export function newIdempotencyKey(): string {
  if (typeof crypto.randomUUID === 'function') return crypto.randomUUID();
  const bytes = crypto.getRandomValues(new Uint8Array(16));
  return Array.from(bytes, (b) => b.toString(16).padStart(2, '0')).join('');
}

export const formatVND = (amount: number) =>
  new Intl.NumberFormat('vi-VN', { style: 'currency', currency: 'VND' }).format(amount);
