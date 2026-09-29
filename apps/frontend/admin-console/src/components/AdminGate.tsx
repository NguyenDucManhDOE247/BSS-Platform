import type { ReactNode } from 'react';
import { useAuth } from 'react-oidc-context';
import { hasRealmRole } from '../auth/oidcConfig';

/**
 * Giai đoạn 9 việc 5: cả admin-console chỉ dành cho role `admin`. Khách hàng (role `customer`) đăng
 * nhập vào đây → thấy thông báo không có quyền, không thấy trang nào. Đây là lớp TRẢI NGHIỆM; lớp bảo
 * mật thật là backend (mọi API quản trị trả 403 với token không có role admin).
 */
export default function AdminGate({ children }: { children: ReactNode }) {
  const auth = useAuth();

  if (auth.isLoading) return <p style={{ padding: 16 }}>Đang kiểm tra đăng nhập…</p>;
  if (auth.error) return <p style={{ padding: 16, color: 'crimson' }}>Lỗi đăng nhập: {auth.error.message}</p>;
  if (!auth.isAuthenticated) {
    return (
      <section style={{ padding: 32 }}>
        <h1>BSS Admin</h1>
        <p>Trang nội bộ dành cho nhân viên. Vui lòng đăng nhập.</p>
        <button onClick={() => void auth.signinRedirect()}>Đăng nhập</button>
      </section>
    );
  }
  if (!hasRealmRole(auth.user?.access_token, 'admin')) {
    return (
      <section style={{ padding: 32 }} data-testid="not-admin">
        <h1>Không có quyền truy cập</h1>
        <p>Tài khoản <strong>{auth.user?.profile.preferred_username}</strong> không có quyền quản trị.</p>
        <button onClick={() => void auth.signoutRedirect()}>Đăng xuất</button>
      </section>
    );
  }
  return <>{children}</>;
}
