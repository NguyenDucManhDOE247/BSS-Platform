import { useQuery } from '@tanstack/react-query';
import { Link } from 'react-router-dom';
import { api, fetchPage, formatVND } from '../api/client';

interface InvoiceSummary { invoiceCount: number; totalAmount: number; totalTax: number; currency: string }

/**
 * Số đếm lấy từ `X-Total-Count` với `limit=1` — server tự đếm, trình duyệt không tải cả danh sách.
 * (Bản cũ đếm `data.length` với `limit=100` → dừng ở 100.)
 */
function useTotal(key: string, url: string, params: Record<string, string> = {}) {
  return useQuery({
    queryKey: ['total', key],
    queryFn: async () => (await fetchPage<unknown>(url, { ...params, limit: 1 })).total,
  });
}

export default function DashboardPage() {
  const customers = useTotal('customers', '/tmf-api/customerManagement/v4/customer');
  const pending = useTotal('pending', '/tmf-api/customerManagement/v4/customer', { status: 'Initialized' });
  const offerings = useTotal('offerings', '/tmf-api/productCatalog/v4/productOffering');
  const orders = useTotal('orders', '/tmf-api/orderManagement/v4/productOrder');
  // Doanh thu tính ở DB (1 câu SQL tổng hợp) — cộng ở trình duyệt từ 1 trang danh sách sẽ sai ngay
  // khi có nhiều hơn 1 trang hóa đơn.
  const revenue = useQuery({
    queryKey: ['revenue'],
    queryFn: async () => (await api.get<InvoiceSummary>('/tmf-api/billingManagement/v4/customerBill/summary')).data,
  });

  // Lỗi → "—" thay vì "…" mãi mãi (vd. 403 khi token hết hạn, service chưa sẵn sàng).
  const show = <T,>(q: { data?: T; isError: boolean }) => (q.isError ? '—' : q.data);

  const tiles = [
    { label: 'Khách hàng', value: show(customers), color: '#0066cc', to: '/customers' },
    { label: 'Chờ duyệt', value: show(pending), color: '#e67e22', to: '/customers?status=Initialized' },
    { label: 'Gói cước', value: show(offerings), color: '#16a085', to: '/offerings' },
    { label: 'Đơn hàng', value: show(orders), color: '#2c3e50', to: '/orders' },
    { label: 'Hóa đơn', value: revenue.isError ? '—' : revenue.data?.invoiceCount, color: '#9b59b6', to: '/bills' },
    {
      label: 'Doanh thu (gồm VAT)',
      value: revenue.isError ? '—' : revenue.data && formatVND(revenue.data.totalAmount),
      color: '#27ae60',
      to: '/bills',
    },
  ];

  return (
    <section>
      <h1>Admin Dashboard</h1>
      <p style={{ color: '#666' }}>Tổng quan toàn hệ thống — chỉ nhân viên có role <code>admin</code>.</p>

      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit, minmax(180px, 1fr))', gap: 16, marginTop: 16 }}>
        {tiles.map((t) => (
          <Link key={t.label} to={t.to} style={{ color: 'inherit' }}>
            <div
              data-testid={`tile-${t.label}`}
              style={{ border: '1px solid #ddd', borderRadius: 8, padding: 16, background: '#fff' }}
            >
              <div style={{ color: '#666', fontSize: 12, textTransform: 'uppercase' }}>{t.label}</div>
              <div style={{ fontSize: 26, fontWeight: 600, color: t.color, marginTop: 8 }}>
                {t.value ?? '…'}
              </div>
            </div>
          </Link>
        ))}
      </div>
      {revenue.data && (
        <p style={{ color: '#666', marginTop: 12 }}>
          Trong đó VAT: {formatVND(revenue.data.totalTax)}.
        </p>
      )}
    </section>
  );
}
