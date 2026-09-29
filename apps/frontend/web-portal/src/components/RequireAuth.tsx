import type { ReactNode } from 'react';
import { useAuth } from 'react-oidc-context';

/**
 * Trang cần đăng nhập (Hồ sơ, Đơn hàng, Hóa đơn). Chưa đăng nhập → hiện nút thay vì tự chuyển trang
 * ngay: người dùng hiểu vì sao phải đăng nhập, và không bị kẹt vòng chuyển hướng khi Keycloak lỗi.
 */
export default function RequireAuth({ children }: { children: ReactNode }) {
  const auth = useAuth();

  if (auth.isLoading) return <p>Đang kiểm tra đăng nhập…</p>;
  if (auth.error) return <p style={{ color: 'crimson' }}>Lỗi đăng nhập: {auth.error.message}</p>;
  if (!auth.isAuthenticated) {
    return (
      <section>
        <p>Bạn cần đăng nhập để xem trang này.</p>
        <button onClick={() => void auth.signinRedirect()}>Đăng nhập</button>{' '}
        <button onClick={() => void auth.signinRedirect({ prompt: 'create' })}>Đăng ký tài khoản</button>
      </section>
    );
  }
  return <>{children}</>;
}
