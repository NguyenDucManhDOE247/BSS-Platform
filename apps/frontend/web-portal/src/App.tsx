import { Routes, Route, Link } from 'react-router-dom';
import { useAuth } from 'react-oidc-context';
import RequireAuth from './components/RequireAuth';
import HomePage from './pages/HomePage';
import PlansPage from './pages/PlansPage';
import OrderPage from './pages/OrderPage';
import BillsPage from './pages/BillsPage';
import MyOrdersPage from './pages/MyOrdersPage';
import ProfilePage from './pages/ProfilePage';

function AccountMenu() {
  const auth = useAuth();
  if (auth.isLoading) return null;
  if (!auth.isAuthenticated) {
    return (
      <span style={{ marginLeft: 'auto', display: 'flex', gap: 8 }}>
        <button onClick={() => void auth.signinRedirect()}>Đăng nhập</button>
        <button onClick={() => void auth.signinRedirect({ prompt: 'create' })}>Đăng ký</button>
      </span>
    );
  }
  const name = auth.user?.profile.name ?? auth.user?.profile.preferred_username;
  return (
    <span style={{ marginLeft: 'auto', display: 'flex', gap: 8, alignItems: 'baseline' }}>
      <span>Xin chào, <strong>{name}</strong></span>
      <button onClick={() => void auth.signoutRedirect()}>Đăng xuất</button>
    </span>
  );
}

export default function App() {
  const auth = useAuth();
  return (
    <div>
      <nav style={{ padding: 16, borderBottom: '1px solid #ddd', display: 'flex', gap: 16, alignItems: 'baseline' }}>
        <strong>BSS Portal</strong>
        <Link to="/">Trang chủ</Link>
        <Link to="/plans">Gói cước</Link>
        {auth.isAuthenticated && (
          <>
            <Link to="/orders">Đơn hàng của tôi</Link>
            <Link to="/bills">Hóa đơn</Link>
            <Link to="/profile">Hồ sơ</Link>
          </>
        )}
        <AccountMenu />
      </nav>
      <main style={{ padding: 16, maxWidth: 960, margin: '0 auto' }}>
        <Routes>
          <Route path="/" element={<HomePage />} />
          <Route path="/plans" element={<PlansPage />} />
          <Route path="/order/:offeringId" element={<OrderPage />} />
          <Route path="/orders" element={<RequireAuth><MyOrdersPage /></RequireAuth>} />
          <Route path="/bills" element={<RequireAuth><BillsPage /></RequireAuth>} />
          <Route path="/profile" element={<RequireAuth><ProfilePage /></RequireAuth>} />
        </Routes>
      </main>
    </div>
  );
}
