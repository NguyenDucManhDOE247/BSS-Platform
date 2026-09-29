import { useQuery } from '@tanstack/react-query';
import { api, formatVND, problemDetail } from '../api/client';

interface Invoice {
  id: string;
  invoiceNumber: string;
  state: string;
  amount: number;
  taxAmount: number;
  currency: string;
  invoiceDate: string;
  dueDate: string;
  paidAt?: string;
  items: { description: string; amount: number }[];
}

/**
 * Giai đoạn 9 việc 4: "Hóa đơn của tôi". Không truyền customerId (trước GĐ9 là id "khách demo" dùng
 * chung) — billing-service tự lọc theo người đang đăng nhập (ADR-008 quyết định 5).
 */
export default function BillsPage() {
  const { data, isLoading, error, refetch, isFetching } = useQuery({
    queryKey: ['bills'],
    queryFn: async () =>
      (await api.get<Invoice[]>('/tmf-api/billingManagement/v4/customerBill?limit=20')).data,
    refetchInterval: 5000, // billing pipeline is async — poll while waiting
  });

  if (isLoading) return <p>Đang tải hóa đơn…</p>;
  if (error) return <p style={{ color: 'crimson' }}>{problemDetail(error, 'Lỗi khi tải hóa đơn.')}</p>;

  return (
    <section>
      <h1>Hóa đơn của bạn</h1>
      <p style={{ color: '#666' }}>
        Hóa đơn được phát hành tự động vài giây sau khi đơn hàng hoàn tất (qua EventBridge → SQS → billing-service).
        {isFetching && ' Đang làm mới…'}
      </p>
      <button onClick={() => void refetch()}>Tải lại</button>

      {!data?.length ? (
        <p style={{ marginTop: 16 }}>Chưa có hóa đơn nào.</p>
      ) : (
        <table style={{ width: '100%', marginTop: 16, borderCollapse: 'collapse' }}>
          <thead>
            <tr>
              <th align="left">Số hóa đơn</th>
              <th align="left">Ngày</th>
              <th align="right">Thuế (VAT)</th>
              <th align="right">Tổng</th>
              <th align="left">Trạng thái</th>
            </tr>
          </thead>
          <tbody>
            {data.map((inv) => (
              <tr key={inv.id} style={{ borderTop: '1px solid #eee' }}>
                <td><code>{inv.invoiceNumber}</code></td>
                <td>{inv.invoiceDate}</td>
                <td align="right">{formatVND(inv.taxAmount)}</td>
                <td align="right"><strong>{formatVND(inv.amount)}</strong></td>
                <td>{inv.state}</td>
              </tr>
            ))}
          </tbody>
        </table>
      )}
    </section>
  );
}
