import { Routes, Route, Link } from 'react-router-dom';
import HomePage from './pages/HomePage';
import PlansPage from './pages/PlansPage';
import OrderPage from './pages/OrderPage';
import BillsPage from './pages/BillsPage';

export default function App() {
  return (
    <div>
      <nav style={{ padding: 16, borderBottom: '1px solid #ddd', display: 'flex', gap: 16, alignItems: 'baseline' }}>
        <strong>BSS Portal</strong>
        <Link to="/">Trang chủ</Link>
        <Link to="/plans">Gói cước</Link>
        <Link to="/bills">Hóa đơn</Link>
      </nav>
      <main style={{ padding: 16, maxWidth: 960, margin: '0 auto' }}>
        <Routes>
          <Route path="/" element={<HomePage />} />
          <Route path="/plans" element={<PlansPage />} />
          <Route path="/order/:offeringId" element={<OrderPage />} />
          <Route path="/bills" element={<BillsPage />} />
        </Routes>
      </main>
    </div>
  );
}
