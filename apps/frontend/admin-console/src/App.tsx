import { Routes, Route, NavLink } from 'react-router-dom';
import { useAuth } from 'react-oidc-context';
import DashboardPage from './pages/DashboardPage';
import CustomersPage from './pages/CustomersPage';
import OfferingsPage from './pages/OfferingsPage';
import OrdersPage from './pages/OrdersPage';
import BillsPage from './pages/BillsPage';

export default function App() {
  const auth = useAuth();
  const name = auth.user?.profile.preferred_username;
  return (
    <div>
      <nav style={{ padding: 16, borderBottom: '1px solid #ddd', background: '#f8f8f8', display: 'flex', gap: 16, alignItems: 'baseline' }}>
        <strong>BSS Admin</strong>
        <NavLink to="/" end>Dashboard</NavLink>
        <NavLink to="/customers">Khách hàng</NavLink>
        <NavLink to="/offerings">Gói cước</NavLink>
        <NavLink to="/orders">Đơn hàng</NavLink>
        <NavLink to="/bills">Hóa đơn</NavLink>
        <span style={{ marginLeft: 'auto', display: 'flex', gap: 8, alignItems: 'baseline' }}>
          <span>Nhân viên: <strong>{name}</strong></span>
          <button onClick={() => void auth.signoutRedirect()}>Đăng xuất</button>
        </span>
      </nav>
      <main style={{ padding: 16, maxWidth: 1100, margin: '0 auto' }}>
        <Routes>
          <Route path="/" element={<DashboardPage />} />
          <Route path="/customers" element={<CustomersPage />} />
          <Route path="/offerings" element={<OfferingsPage />} />
          <Route path="/orders" element={<OrdersPage />} />
          <Route path="/bills" element={<BillsPage />} />
        </Routes>
      </main>
    </div>
  );
}
