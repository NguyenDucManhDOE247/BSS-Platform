import { useQuery } from '@tanstack/react-query';
import { api, formatVND, problemDetail } from '../api/client';

interface Order {
  id: string;
  state: string;
  totalAmount: number;
  createdAt: string;
  items: { productOfferingName: string; quantity: number; unitPrice: number }[];
}

/**
 * Giai đoạn 9 việc 4: "Đơn hàng của tôi". Không truyền customerId — order-management tự lọc theo
 * người đang đăng nhập (ADR-008 quyết định 5); giá hiển thị là giá TẠI THỜI ĐIỂM MUA (B-13), admin đổi
 * giá gói sau đó không ảnh hưởng.
 */
export default function MyOrdersPage() {
  const { data, isLoading, error } = useQuery({
    queryKey: ['my-orders'],
    queryFn: async () => (await api.get<Order[]>('/tmf-api/orderManagement/v4/productOrder?limit=50')).data,
  });

  if (isLoading) return <p>Đang tải đơn hàng…</p>;
  if (error) return <p style={{ color: 'crimson' }}>{problemDetail(error, 'Lỗi khi tải đơn hàng.')}</p>;

  return (
    <section>
      <h1>Đơn hàng của tôi</h1>
      {!data?.length ? (
        <p>Bạn chưa có đơn hàng nào.</p>
      ) : (
        <table style={{ width: '100%', borderCollapse: 'collapse' }}>
          <thead>
            <tr>
              <th align="left">Ngày</th>
              <th align="left">Gói</th>
              <th align="right">Tổng</th>
              <th align="left">Trạng thái</th>
            </tr>
          </thead>
          <tbody>
            {data.map((o) => (
              <tr key={o.id} style={{ borderTop: '1px solid #eee' }}>
                <td>{new Date(o.createdAt).toLocaleString('vi-VN')}</td>
                <td>{o.items.map((i) => i.productOfferingName).join(', ')}</td>
                <td align="right"><strong>{formatVND(o.totalAmount)}</strong></td>
                <td>{o.state}</td>
              </tr>
            ))}
          </tbody>
        </table>
      )}
    </section>
  );
}
