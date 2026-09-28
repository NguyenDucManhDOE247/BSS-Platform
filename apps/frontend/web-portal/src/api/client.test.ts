import { afterEach, describe, expect, it } from 'vitest';
import { User } from 'oidc-client-ts';
import type { InternalAxiosRequestConfig } from 'axios';
import { api, formatVND } from './client';
import { OIDC_AUTHORITY, OIDC_CLIENT_ID } from '../auth/oidcConfig';

// B-04 fix: ci-frontend.yml runs `npm test` (vitest run) and there wasn't a single test file
// in either frontend app — `vitest run` with zero test files exits non-zero, so CI was
// guaranteed red the moment someone actually looked at it, regardless of what the app code did.
// Intl.NumberFormat('vi-VN', ...) separates the amount from the ₫ symbol with U+00A0
// NO-BREAK SPACE, not a regular U+0020 space — they render identically in a terminal/editor
// but fail a strict string `toBe` comparison against a literal typed with a normal space.
// Found by actually running this test, not by guessing at the expected output.
// Giai đoạn 9: tạo NBSP bằng String.fromCharCode(0xa0) thay vì gõ thẳng ký tự đó. Khi viết lại file
// này, ký tự NBSP gõ thẳng đã bị đổi ngầm thành dấu cách thường (nhìn giống hệt) → 2 test đỏ; code
// chỉ gồm ký tự ASCII thì không thể bị đổi ngầm như vậy (ESLint no-irregular-whitespace cũng hết phàn nàn).
const NBSP = String.fromCharCode(0xa0);

describe('formatVND', () => {
  it('formats a whole VND amount with the currency symbol', () => {
    expect(formatVND(199000)).toBe(`199.000${NBSP}₫`);
  });

  it('formats zero', () => {
    expect(formatVND(0)).toBe(`0${NBSP}₫`);
  });
});

/**
 * Giai đoạn 9 (ADR-008): interceptor gắn Bearer token của người đang đăng nhập. Chặn request ở tầng
 * adapter (không gửi ra mạng) để đọc đúng header axios SẼ gửi.
 */
describe('api interceptor', () => {
  const storageKey = `oidc.user:${OIDC_AUTHORITY}:${OIDC_CLIENT_ID}`;

  async function headersSent(): Promise<Record<string, unknown>> {
    let captured: InternalAxiosRequestConfig | undefined;
    await api.get('/x', {
      adapter: async (config) => {
        captured = config;
        return { data: null, status: 200, statusText: 'OK', headers: {}, config };
      },
    });
    return captured!.headers.toJSON();
  }

  function storeUser(expiresInSeconds: number) {
    const user = new User({
      access_token: 'token-cua-khach',
      token_type: 'Bearer',
      profile: { sub: 'sub-1', iss: OIDC_AUTHORITY, aud: OIDC_CLIENT_ID, exp: 0, iat: 0 },
      expires_at: Math.floor(Date.now() / 1000) + expiresInSeconds,
    });
    window.sessionStorage.setItem(storageKey, user.toStorageString());
  }

  afterEach(() => window.sessionStorage.clear());

  it('attaches the logged-in user access token', async () => {
    storeUser(300);
    expect((await headersSent()).Authorization).toBe('Bearer token-cua-khach');
  });

  it('sends no Authorization header when not logged in (public browsing still works)', async () => {
    expect((await headersSent()).Authorization).toBeUndefined();
  });

  it('does not send an expired token', async () => {
    storeUser(-10);
    expect((await headersSent()).Authorization).toBeUndefined();
  });
});
