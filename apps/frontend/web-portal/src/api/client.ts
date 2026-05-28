import axios from 'axios';

// Vite dev proxy routes /api → api-gateway:8080. In prod the ALB does the same.
export const api = axios.create({
  baseURL: '/api',
  headers: { Accept: 'application/json' },
});

/**
 * Portfolio demo: in real life this would come from an auth session.
 * Pinning a fixed UUID lets us demo per-customer pages without an auth flow.
 */
export const DEMO_CUSTOMER_ID = '00000000-0000-0000-0000-000000000001';

export const formatVND = (amount: number) =>
  new Intl.NumberFormat('vi-VN', { style: 'currency', currency: 'VND' }).format(amount);
