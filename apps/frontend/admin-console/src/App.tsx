import { Routes, Route, Link } from 'react-router-dom';
import DashboardPage from './pages/DashboardPage';
import CustomersPage from './pages/CustomersPage';
import OfferingsPage from './pages/OfferingsPage';

export default function App() {
  return (
    <div>
      <nav style={{ padding: 16, borderBottom: '1px solid #ddd', background: '#f8f8f8', display: 'flex', gap: 16, alignItems: 'baseline' }}>
        <strong>BSS Admin</strong>
        <Link to="/">Dashboard</Link>
        <Link to="/customers">Customers</Link>
        <Link to="/offerings">Catalog</Link>
      </nav>
      <main style={{ padding: 16, maxWidth: 1100, margin: '0 auto' }}>
        <Routes>
          <Route path="/" element={<DashboardPage />} />
          <Route path="/customers" element={<CustomersPage />} />
          <Route path="/offerings" element={<OfferingsPage />} />
        </Routes>
      </main>
    </div>
  );
}
