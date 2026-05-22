import { Routes, Route, Link } from 'react-router-dom';

function Dashboard() {
  return (
    <section>
      <h1>Admin Dashboard</h1>
      <p>Internal-only console for ops and customer support staff.</p>
    </section>
  );
}

function CustomersPage() {
  return (
    <section>
      <h1>Customers</h1>
      <p>TODO: search + manage TMF629 customers.</p>
    </section>
  );
}

export default function App() {
  return (
    <div>
      <nav style={{ padding: 16, borderBottom: '1px solid #ddd', background: '#f8f8f8' }}>
        <strong style={{ marginRight: 16 }}>BSS Admin</strong>
        <Link to="/" style={{ marginRight: 12 }}>Dashboard</Link>
        <Link to="/customers">Customers</Link>
      </nav>
      <main style={{ padding: 16 }}>
        <Routes>
          <Route path="/" element={<Dashboard />} />
          <Route path="/customers" element={<CustomersPage />} />
        </Routes>
      </main>
    </div>
  );
}
