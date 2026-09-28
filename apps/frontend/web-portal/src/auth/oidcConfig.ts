import type { AuthProviderProps } from 'react-oidc-context';
import { User, WebStorageStateStore } from 'oidc-client-ts';

/**
 * Giai đoạn 9 việc 4 — ADR-008 quyết định 1, 2.
 *
 * Luồng Authorization Code + PKCE: web-portal KHÔNG BAO GIỜ thấy mật khẩu người dùng — trình duyệt
 * được chuyển sang trang đăng nhập/đăng ký của Keycloak, rồi quay về đây kèm `code`; oidc-client-ts
 * đổi `code` (+ code_verifier PKCE) lấy token.
 *
 * Địa chỉ Keycloak (ADR-008 quyết định 2):
 * - bản build (kind, AWS): cùng origin + `/auth/realms/bss` → 1 image chạy mọi môi trường;
 * - `npm run dev` (Vite, localhost:3000): Keycloak của docker-compose ở localhost:8180 — khác origin.
 * `VITE_OIDC_AUTHORITY` ghi đè cả 2 nếu cần. Không dùng file `.env.development`: `.gitignore` chặn
 * mọi `.env.*` (chống lỡ commit secret) và không nên nới quy tắc đó chỉ để lưu 1 địa chỉ.
 */
const DEV_AUTHORITY = 'http://localhost:8180/auth/realms/bss';

export const OIDC_AUTHORITY =
  import.meta.env.VITE_OIDC_AUTHORITY
  ?? (import.meta.env.DEV ? DEV_AUTHORITY : `${window.location.origin}/auth/realms/bss`);

export const OIDC_CLIENT_ID = 'web-portal';

export const oidcConfig: AuthProviderProps = {
  authority: OIDC_AUTHORITY,
  client_id: OIDC_CLIENT_ID,
  redirect_uri: `${window.location.origin}/`,
  post_logout_redirect_uri: `${window.location.origin}/`,
  scope: 'openid profile email',
  // sessionStorage (mặc định của thư viện, ghi rõ ra cho người đọc): mất khi đóng tab. Đánh đổi đã
  // ghi trong ADR-008 quyết định 1 — vẫn đọc được nếu trang bị XSS; BFF là hướng nâng cấp nếu cần.
  userStore: new WebStorageStateStore({ store: window.sessionStorage }),
  // Tự làm mới access token (5 phút ở Keycloak mặc định) bằng refresh token trước khi hết hạn.
  automaticSilentRenew: true,
  // Sau khi Keycloak chuyển về kèm ?code=...&state=..., xóa 2 tham số đó khỏi thanh địa chỉ —
  // không để lại code dùng 1 lần trong lịch sử trình duyệt / khi người dùng copy link.
  onSigninCallback: () => {
    window.history.replaceState({}, document.title, window.location.pathname);
  },
};

/**
 * Lấy access token cho axios (ngoài cây React), đúng cách README của react-oidc-context hướng dẫn:
 * đọc User mà oidc-client-ts đã lưu trong sessionStorage. Trả undefined nếu chưa đăng nhập / hết hạn.
 */
export function currentAccessToken(): string | undefined {
  const raw = window.sessionStorage.getItem(`oidc.user:${OIDC_AUTHORITY}:${OIDC_CLIENT_ID}`);
  if (!raw) return undefined;
  const user = User.fromStorageString(raw);
  return user.expired ? undefined : user.access_token;
}
