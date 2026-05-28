import { useQuery } from '@tanstack/react-query';
import { api } from '../api/client';

interface Counted { length: number }

function useCount<T extends Counted>(url: string, key: string) {
  return useQuery({
    queryKey: [key],
    queryFn: async () => (await api.get<T>(url)).data,
  });
}

export default function DashboardPage() {
  const customers = useCount<{ length: number } & unknown[]>(
    '/tmf-api/customerManagement/v4/customer?limit=100', 'cust-count');
  const offerings = useCount<{ length: number } & unknown[]>(
    '/tmf-api/productCatalog/v4/productOffering?limit=100', 'off-count');
  const accounts = useCount<{ length: number } & unknown[]>(
    '/tmf-api/billingManagement/v4/billingAccount?limit=100', 'acc-count');

  const tiles = [
    { label: 'Customers',         count: customers.data?.length, color: '#0066cc' },
    { label: 'Product Offerings', count: offerings.data?.length, color: '#16a085' },
    { label: 'Billing Accounts',  count: accounts.data?.length,  color: '#9b59b6' },
  ];

  return (
    <section>
      <h1>Admin Dashboard</h1>
      <p style={{ color: '#666' }}>Internal-only console for ops and customer support staff.</p>

      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit, minmax(180px, 1fr))', gap: 16, marginTop: 16 }}>
        {tiles.map((t) => (
          <div key={t.label} style={{ border: '1px solid #ddd', borderRadius: 8, padding: 16, background: '#fff' }}>
            <div style={{ color: '#666', fontSize: 12, textTransform: 'uppercase' }}>{t.label}</div>
            <div style={{ fontSize: 28, fontWeight: 600, color: t.color, marginTop: 8 }}>
              {t.count ?? '…'}
            </div>
          </div>
        ))}
      </div>
    </section>
  );
}
