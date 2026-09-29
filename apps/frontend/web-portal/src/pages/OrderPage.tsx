import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { useAuth } from 'react-oidc-context';
import { useParams, Link, useNavigate } from 'react-router-dom';
import { api, formatVND, problemDetail } from '../api/client';
import { statusText, useMyProfile } from '../hooks/useMyProfile';

interface ProductOffering {
  id: string;
  name: string;
  description?: string;
  priceAmount: number;
  priceCurrency: string;
}

/**
 * Giai đoạn 9 việc 4. Trước GĐ9 trang này gửi `customerId` của 1 "khách demo" cố định (khách "ma" dùng chung
 * cho mọi người) + `unitPrice` do client tự khai. Giờ body chỉ còn gói + số lượng: order-management tự
 * biết khách LÀ AI (token) và GIÁ bao nhiêu (product-catalog) — ADR-008, B-13.
 */
export default function OrderPage() {
  const { offeringId } = useParams<{ offeringId: string }>();
  const auth = useAuth();
  const queryClient = useQueryClient();
  const navigate = useNavigate();
  const { data: me, isLoading: meLoading } = useMyProfile();

  const { data: offering, isLoading } = useQuery({
    queryKey: ['offering', offeringId],
    queryFn: async () =>
      (await api.get<ProductOffering>(`/tmf-api/productCatalog/v4/productOffering/${offeringId}`)).data,
    enabled: !!offeringId,
  });

  const placeOrder = useMutation({
    mutationFn: async () => {
      if (!offering) throw new Error('No offering');
      return (await api.post('/tmf-api/orderManagement/v4/productOrder', {
        category: 'new',
        description: `Subscription: ${offering.name}`,
        items: [{ productOfferingId: offering.id, quantity: 1 }],
      })).data;
    },
    onSuccess: () => {
      void queryClient.invalidateQueries({ queryKey: ['bills'] });
      void queryClient.invalidateQueries({ queryKey: ['my-orders'] });
      navigate('/orders');
    },
  });

  if (isLoading) return <p>Đang tải gói cước…</p>;
  if (!offering) return <p>Không tìm thấy gói cước (có thể gói đã ngừng bán).</p>;

  return (
    <section>
      <h1>Xác nhận đăng ký</h1>
      <article className="plan-card">
        <h2>{offering.name}</h2>
        {offering.description && <p>{offering.description}</p>}
        <p className="plan-card__price">{formatVND(offering.priceAmount)} /tháng</p>
      </article>

      <div style={{ marginTop: 16 }}>
        {!auth.isAuthenticated ? (
          <p>
            <button onClick={() => void auth.signinRedirect()}>Đăng nhập để đăng ký gói</button>{' '}
            hoặc <button onClick={() => void auth.signinRedirect({ prompt: 'create' })}>tạo tài khoản mới</button>
          </p>
        ) : meLoading ? (
          <p>Đang kiểm tra hồ sơ…</p>
        ) : me === null ? (
          <p>Bạn cần <Link to="/profile">hoàn tất hồ sơ khách hàng</Link> trước khi đăng ký gói.</p>
        ) : me && me.status !== 'Active' ? (
          <p data-testid="not-active">{statusText[me.status]}</p>
        ) : (
          <div style={{ display: 'flex', gap: 8 }}>
            <button onClick={() => placeOrder.mutate()} disabled={placeOrder.isPending}>
              {placeOrder.isPending ? 'Đang xử lý…' : 'Xác nhận đăng ký'}
            </button>
            <Link to="/plans">Hủy</Link>
          </div>
        )}
        {placeOrder.isError && (
          <p style={{ color: 'crimson' }}>{problemDetail(placeOrder.error, 'Tạo đơn thất bại — thử lại sau.')}</p>
        )}
      </div>
    </section>
  );
}
