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
 * (Trước GĐ9 ở đây là `DEMO_CUSTOMER_ID` — 1 khách cố định dùng chung cho MỌI người, không tồn tại
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

export const formatVND = (amount: number) =>
  new Intl.NumberFormat('vi-VN', { style: 'currency', currency: 'VND' }).format(amount);
