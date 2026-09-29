import { afterEach, describe, expect, it, vi } from 'vitest';
import { AxiosError, AxiosHeaders, type AxiosResponse } from 'axios';
import { api, fetchPage, problemDetail } from './client';

function response<T>(data: T, headers: Record<string, string>): AxiosResponse<T> {
  return { data, status: 200, statusText: 'OK', headers, config: { headers: new AxiosHeaders() } };
}

describe('fetchPage', () => {
  afterEach(() => { vi.restoreAllMocks(); });

  it('returns the real total from X-Total-Count, not the page length', async () => {
    vi.spyOn(api, 'get').mockResolvedValue(response([{ id: 1 }], { 'x-total-count': '250' }));
    expect(await fetchPage('/x', { limit: 1 })).toEqual({ rows: [{ id: 1 }], total: 250 });
  });

  it('drops empty filters instead of sending ?q= to the server', async () => {
    const get = vi.spyOn(api, 'get').mockResolvedValue(response([], {}));
    await fetchPage('/x', { q: '', status: undefined, customerId: 'c1', offset: 0 });
    expect(get).toHaveBeenCalledWith('/x', { params: { customerId: 'c1', offset: 0 } });
  });
});

describe('problemDetail', () => {
  it('uses the RFC 7807 detail from the server when present', () => {
    const err = new AxiosError('x', '409', undefined, undefined,
      response({ detail: 'Email đã tồn tại' }, {}) as AxiosResponse);
    expect(problemDetail(err, 'fallback')).toBe('Email đã tồn tại');
  });

  it('falls back for non-HTTP errors', () => {
    expect(problemDetail(new Error('boom'), 'fallback')).toBe('fallback');
  });
});
