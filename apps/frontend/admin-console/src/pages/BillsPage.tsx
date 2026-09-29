import { useQuery } from '@tanstack/react-query';
import { Fragment, useState } from 'react';
import { useSearchParams } from 'react-router-dom';
import { fetchPage, formatVND } from '../api/client';
import CustomerFilter from '../components/CustomerFilter';
import Pager from '../components/Pager';

interface InvoiceItem {
  id: string;
  description: string;
  sourceOrderId?: string;
  quantity: number;
  unitPrice: number;
  amount: number;
}

interface Invoice {
  id: string;
  billingAccountId: string;
  invoiceNumber: string;
  state: string;
  amount: number;
  taxAmount: number;
  currency: string;
  invoiceDate: string;
  dueDate: string;
  paidAt?: string;
  items: InvoiceItem[];
}

const LIMIT = 20;

/** Hóa đơn TOÀN HỆ THỐNG (admin), lọc theo khách qua `?customerId=`. */
export default function BillsPage() {
  const [params, setParams] = useSearchParams();
  const customerId = params.get('customerId') ?? '';
  const offset = Number(params.get('offset') ?? 0);
  const [open, setOpen] = useState<string | null>(null);

  const setParam = (changes: Record<string, string>) => {
    const next = new URLSearchParams(params);
    for (const [k, v] of Object.entries(changes)) { if (v) next.set(k, v); else next.delete(k); }
    setParams(next);
  };

  const bills = useQuery({
    queryKey: ['bills', customerId, offset],
    queryFn: () => fetchPage<Invoice>('/tmf-api/billingManagement/v4/customerBill', { customerId, offset, limit: LIMIT }),
  });

  return (
    <section>
      <h1>Hóa đơn (TMF678)</h1>
      <CustomerFilter key={customerId} customerId={customerId} onChange={(id) => setParam({ customerId: id, offset: '' })} />

      {bills.isLoading && <p>Đang tải…</p>}
      {bills.error && <p style={{ color: 'crimson' }}>Lỗi tải danh sách hóa đơn.</p>}
      {bills.data && bills.data.rows.length === 0 && <p>Chưa có hóa đơn nào.</p>}
      {bills.data && bills.data.rows.length > 0 && (
        <table style={{ width: '100%', borderCollapse: 'collapse' }}>
          <thead>
            <tr>
              <th align="left">Số hóa đơn</th>
              <th align="left">Ngày</th>
              <th align="left">Hạn</th>
              <th align="right">Tổng (gồm VAT)</th>
              <th align="left">Trạng thái</th>
              <th></th>
            </tr>
          </thead>
          <tbody>
            {bills.data.rows.map((b) => (
              <Fragment key={b.id}>
                <tr data-testid="bill-row" style={{ borderTop: '1px solid #eee' }}>
                  <td><code>{b.invoiceNumber}</code></td>
                  <td>{b.invoiceDate}</td>
                  <td>{b.dueDate}</td>
                  <td align="right">{formatVND(b.amount)}</td>
                  <td>{b.state}</td>
                  <td>
                    <button onClick={() => setOpen(open === b.id ? null : b.id)}>
                      {open === b.id ? 'Ẩn' : 'Chi tiết'}
                    </button>
                  </td>
                </tr>
                {open === b.id && (
                  <tr data-testid="bill-detail">
                    <td colSpan={6} style={{ background: '#f4f6f8' }}>
                      <div><strong>Tài khoản thanh toán:</strong> <code>{b.billingAccountId}</code></div>
                      <div><strong>Thanh toán lúc:</strong> {b.paidAt ? new Date(b.paidAt).toLocaleString('vi-VN') : 'chưa thanh toán'}</div>
                      <table style={{ marginTop: 8 }}>
                        <thead>
                          <tr><th align="left">Nội dung</th><th align="right">SL</th><th align="right">Đơn giá</th><th align="right">Thành tiền</th></tr>
                        </thead>
                        <tbody>
                          {b.items.map((i) => (
                            <tr key={i.id}>
                              <td>{i.description}</td>
                              <td align="right">{i.quantity}</td>
                              <td align="right">{formatVND(i.unitPrice)}</td>
                              <td align="right">{formatVND(i.amount)}</td>
                            </tr>
                          ))}
                          <tr><td colSpan={3} align="right">VAT</td><td align="right">{formatVND(b.taxAmount)}</td></tr>
                          <tr><td colSpan={3} align="right"><strong>Tổng</strong></td><td align="right"><strong>{formatVND(b.amount)}</strong></td></tr>
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
      {bills.data && (
        <Pager offset={offset} limit={LIMIT} total={bills.data.total} onChange={(o) => setParam({ offset: String(o) })} />
      )}
    </section>
  );
}
