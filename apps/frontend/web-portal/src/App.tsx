import { Routes, Route, Link } from 'react-router-dom';
import HomePage from './pages/HomePage';
import PlansPage from './pages/PlansPage';

export default function App() {
  return (
    <div>
      <nav style={{ padding: 16, borderBottom: '1px solid #ddd' }}>
        <strong style={{ marginRight: 16 }}>BSS Portal</strong>
        <Link to="/" style={{ marginRight: 12 }}>Home</Link>
        <Link to="/plans">Plans</Link>
      </nav>
      <main style={{ padding: 16 }}>
        <Routes>
          <Route path="/" element={<HomePage />} />
          <Route path="/plans" element={<PlansPage />} />
        </Routes>
      </main>
    </div>
  );
}
