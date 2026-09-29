import type { AuthProviderProps } from 'react-oidc-context';
import { User, WebStorageStateStore } from 'oidc-client-ts';

/**
 * Giai đoạn 9 việc 5 — ADR-008 quyết định 1, 2, 7. Cùng cách với web-portal (xem file cùng tên ở
 * đó để có giải thích đầy đủ); khác: client `admin-console`, mọi URL nằm dưới `/admin/` (B-06).
 * (2 app giữ 2 bản vì chưa có thư viện dùng chung thật sự — packages/ui-kit chưa được app nào dùng.)
 */
const DEV_AUTHORITY = 'http://localhost:8180/auth/realms/bss';

export const OIDC_AUTHORITY =
  import.meta.env.VITE_OIDC_AUTHORITY
  ?? (import.meta.env.DEV ? DEV_AUTHORITY : `${window.location.origin}/auth/realms/bss`);

export const OIDC_CLIENT_ID = 'admin-console';

/**
 * Gốc của app = `<origin>/admin/` — `base: '/admin/'` trong vite.config.ts áp dụng cả khi build lẫn
 * Vite dev, nên khớp redirect URI của client `admin-console` trong realm (`/admin/*` và `localhost:3001/*`).
 */
const APP_ROOT = `${window.location.origin}${import.meta.env.BASE_URL}`;

export const oidcConfig: AuthProviderProps = {
  authority: OIDC_AUTHORITY,
  client_id: OIDC_CLIENT_ID,
  redirect_uri: APP_ROOT,
  post_logout_redirect_uri: APP_ROOT,
  scope: 'openid profile email',
  userStore: new WebStorageStateStore({ store: window.sessionStorage }),
  automaticSilentRenew: true,
  onSigninCallback: () => {
    window.history.replaceState({}, document.title, window.location.pathname);
  },
};

export function currentAccessToken(): string | undefined {
  const raw = window.sessionStorage.getItem(`oidc.user:${OIDC_AUTHORITY}:${OIDC_CLIENT_ID}`);
  if (!raw) return undefined;
  const user = User.fromStorageString(raw);
  return user.expired ? undefined : user.access_token;
}

/**
 * Role nằm trong ACCESS token (`realm_access.roles`), không có trong ID token mà `user.profile` đọc —
 * Keycloak mặc định chỉ map realm roles vào access token. Giải mã phần payload (base64url) chỉ để
 * QUYẾT ĐỊNH HIỂN THỊ; bảo mật thật nằm ở backend, nơi chữ ký token được kiểm (ADR-008 quyết định 4).
 */
export function hasRealmRole(accessToken: string | undefined, role: string): boolean {
  if (!accessToken) return false;
  try {
    const payload = accessToken.split('.')[1].replace(/-/g, '+').replace(/_/g, '/');
    const claims = JSON.parse(atob(payload)) as { realm_access?: { roles?: string[] } };
    return claims.realm_access?.roles?.includes(role) ?? false;
  } catch {
    return false;
  }
}
