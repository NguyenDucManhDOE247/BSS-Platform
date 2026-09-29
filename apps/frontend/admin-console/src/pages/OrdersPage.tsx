import { useQuery } from '@tanstack/react-query';
import { Fragment, useState } from 'react';
import { Link, useSearchParams } from 'react-router-dom';
import { fetchPage, formatVND } from '../api/client';
import CustomerFilter from '../components/CustomerFilter';
import Pager from '../components/Pager';

interface OrderItem {
  id: string;
  productOfferingId: string;
  productOfferingName: string;
  quantity: number;
  unitPrice: number;
}

interface Order {
  id: string;
  customerId: string;
  state: string;
  description?: string;
  totalAmount: number;
  currency: string;
  completedAt?: string;
  createdAt: string;
  items: OrderItem[];
}

const LIMIT = 20;

/** Đơn hàng TOÀN HỆ THỐNG (admin) — khác "Đơn hàng của tôi" ở web-portal (server lọc theo người gọi). */
export default function OrdersPage() {
  const [params, setParams] = useSearchParams();
  const customerId = params.get('customerId') ?? '';
  const offset = Number(params.get('offset') ?? 0);
  const [open, setOpen] = useState<string | null>(null);

  const setParam = (changes: Record<string, string>) => {
    const next = new URLSearchParams(params);
    for (const [k, v] of Object.entries(changes)) { if (v) next.set(k, v); else next.delete(k); }
    setParams(next);
  };

  const orders = useQuery({
    queryKey: ['orders', customerId, offset],
    queryFn: () => fetchPage<Order>('/tmf-api/orderManagement/v4/productOrder', { customerId, offset, limit: LIMIT }),
  });

  return (
    <section>
      <h1>Đơn hàng (TMF622)</h1>
      <CustomerFilter key={customerId} customerId={customerId} onChange={(id) => setParam({ customerId: id, offset: '' })} />

      {orders.isLoading && <p>Đang tải…</p>}
      {orders.error && <p style={{ color: 'crimson' }}>Lỗi tải danh sách đơn.</p>}
      {orders.data && orders.data.rows.length === 0 && <p>Chưa có đơn hàng nào.</p>}
      {orders.data && orders.data.rows.length > 0 && (
        <table style={{ width: '100%', borderCollapse: 'collapse' }}>
          <thead>
            <tr>
              <th align="left">Ngày tạo</th>
              <th align="left">Khách hàng</th>
              <th align="left">Gói</th>
              <th align="right">Tổng</th>
              <th align="left">Trạng thái</th>
              <th></th>
            </tr>
          </thead>
          <tbody>
            {orders.data.rows.map((o) => (
              <Fragment key={o.id}>
                <tr data-testid="order-row" style={{ borderTop: '1px solid #eee' }}>
                  <td>{new Date(o.createdAt).toLocaleString('vi-VN')}</td>
                  <td>
                    <Link to={`/orders?customerId=${o.customerId}`} title={o.customerId}>
                      <code>{o.customerId.slice(0, 8)}</code>
                    </Link>
                  </td>
                  <td>{o.items.map((i) => i.productOfferingName).join(', ')}</td>
                  <td align="right">{formatVND(o.totalAmount)}</td>
                  <td>{o.state}</td>
                  <td>
                    <button onClick={() => setOpen(open === o.id ? null : o.id)}>
                      {open === o.id ? 'Ẩn' : 'Chi tiết'}
                    </button>
                  </td>
                </tr>
                {open === o.id && (
                  <tr data-testid="order-detail">
                    <td colSpan={6} style={{ background: '#f4f6f8' }}>
                      <div><strong>Mã đơn:</strong> <code>{o.id}</code></div>
                      <div><strong>Mã khách:</strong> <code>{o.customerId}</code></div>
                      {o.description && <div><strong>Ghi chú:</strong> {o.description}</div>}
                      <div><strong>Hoàn tất:</strong> {o.completedAt ? new Date(o.completedAt).toLocaleString('vi-VN') : '—'}</div>
                      <table style={{ marginTop: 8 }}>
                        <thead><tr><th align="left">Gói</th><th align="right">SL</th><th align="right">Đơn giá lúc mua</th></tr></thead>
                        <tbody>
                          {o.items.map((i) => (
                            <tr key={i.id}>
                              <td>{i.productOfferingName}</td>
                              <td align="right">{i.quantity}</td>
                              <td align="right">{formatVND(i.unitPrice)}</td>
                            </tr>
                          ))}
                        </tbody>
                      </table>
                    </td>
                  </tr>
                )}
              </Fragment>
            ))}
          </tbody>
        </table>
      )}
      {orders.data && (
        <Pager offset={offset} limit={LIMIT} total={orders.data.total} onChange={(o) => setParam({ offset: String(o) })} />
      )}
    </section>
  );
}
