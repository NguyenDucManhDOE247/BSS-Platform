import { useQuery } from '@tanstack/react-query';
import { api, DEMO_CUSTOMER_ID, formatVND } from '../api/client';

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

export default function BillsPage() {
  const { data, isLoading, error, refetch, isFetching } = useQuery({
    queryKey: ['bills', DEMO_CUSTOMER_ID],
    queryFn: async () => {
      const res = await api.get<Invoice[]>(
        `/tmf-api/billingManagement/v4/customerBill?customerId=${DEMO_CUSTOMER_ID}&limit=20`,
      );
      return res.data;
    },
    refetchInterval: 5000, // billing pipeline is async — poll while waiting
  });

  if (isLoading) return <p>Đang tải hóa đơn…</p>;
  if (error) return <p>Lỗi khi tải hóa đơn.</p>;

  return (
    <section>
      <h1>Hóa đơn của bạn</h1>
      <p style={{ color: '#666' }}>
        Hóa đơn được phát hành tự động sau khi đơn hàng hoàn tất (qua EventBridge → SQS → billing-service).
        {isFetching && ' Đang làm mới…'}
      </p>
      <button onClick={() => refetch()}>Tải lại</button>

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
