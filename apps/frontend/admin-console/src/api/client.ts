import axios, { isAxiosError, type AxiosResponse } from 'axios';
import { currentAccessToken } from '../auth/oidcConfig';

export const api = axios.create({
  baseURL: '/api',
  headers: { Accept: 'application/json' },
});

/** Giai đoạn 9 (ADR-008): mọi request gắn token admin. Trước GĐ9 admin-console gọi API không token. */
api.interceptors.request.use((config) => {
  const token = currentAccessToken();
  if (token) config.headers.set('Authorization', `Bearer ${token}`);
  return config;
});

/**
 * Tổng số bản ghi thật (header `X-Total-Count`), không phải số phần tử trả về. Dashboard cũ đếm
 * `data.length` với `limit=100` → sai (dừng ở 100) ngay khi có hơn 100 khách/gói.
 */
export function totalCount(res: AxiosResponse): number {
  return Number(res.headers['x-total-count'] ?? 0);
}

export interface Page<T> { rows: T[]; total: number }

/** 1 trang danh sách + tổng thật. Tham số rỗng/undefined bị bỏ, không gửi `?q=` rỗng lên server. */
export async function fetchPage<T>(url: string, params: Record<string, string | number | undefined>): Promise<Page<T>> {
  const clean = Object.fromEntries(Object.entries(params).filter(([, v]) => v !== undefined && v !== ''));
  const res = await api.get<T[]>(url, { params: clean });
  return { rows: res.data, total: totalCount(res) };
}

export function problemDetail(err: unknown, fallback: string): string {
  if (isAxiosError(err)) {
    const detail: unknown = err.response?.data?.detail;
    if (typeof detail === 'string' && detail.length > 0) return detail;
  }
  return fallback;
}

export const formatVND = (amount: number) =>
  new Intl.NumberFormat('vi-VN', { style: 'currency', currency: 'VND' }).format(amount);
