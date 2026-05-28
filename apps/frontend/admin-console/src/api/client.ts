import axios from 'axios';

export const api = axios.create({
  baseURL: '/api',
  headers: { Accept: 'application/json' },
});

export const formatVND = (amount: number) =>
  new Intl.NumberFormat('vi-VN', { style: 'currency', currency: 'VND' }).format(amount);
