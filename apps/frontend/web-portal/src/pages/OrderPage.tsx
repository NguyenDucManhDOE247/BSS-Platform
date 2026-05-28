import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { useParams, Link, useNavigate } from 'react-router-dom';
import { api, DEMO_CUSTOMER_ID, formatVND } from '../api/client';

interface ProductOffering {
  id: string;
  name: string;
  description?: string;
  priceAmount: number;
  priceCurrency: string;
}

interface CreateOrderResponse {
  id: string;
  state: string;
  totalAmount: number;
}

export default function OrderPage() {
  const { offeringId } = useParams<{ offeringId: string }>();
  const queryClient = useQueryClient();
  const navigate = useNavigate();

  const { data: offering, isLoading } = useQuery({
    queryKey: ['offering', offeringId],
    queryFn: async () => {
      const res = await api.get<ProductOffering>(
        `/tmf-api/productCatalog/v4/productOffering/${offeringId}`,
      );
      return res.data;
    },
    enabled: !!offeringId,
  });

  const placeOrder = useMutation({
    mutationFn: async () => {
      if (!offering) throw new Error('No offering');
      const body = {
        customerId: DEMO_CUSTOMER_ID,
        category: 'new',
        description: `Subscription: ${offering.name}`,
        items: [
          {
            productOfferingId: offering.id,
            productOfferingName: offering.name,
            quantity: 1,
            unitPrice: offering.priceAmount,
          },
        ],
      };
      const res = await api.post<CreateOrderResponse>(
        '/tmf-api/orderManagement/v4/productOrder',
        body,
      );
      return res.data;
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ['bills'] });
      navigate('/bills');
    },
  });

  if (isLoading) return <p>Đang tải gói cước…</p>;
  if (!offering) return <p>Không tìm thấy gói cước.</p>;

  return (
    <section>
      <h1>Xác nhận đăng ký</h1>
      <article className="plan-card">
        <h2>{offering.name}</h2>
        {offering.description && <p>{offering.description}</p>}
        <p className="plan-card__price">{formatVND(offering.priceAmount)} /tháng</p>
      </article>

      <div style={{ marginTop: 16, display: 'flex', gap: 8 }}>
        <button
          onClick={() => placeOrder.mutate()}
          disabled={placeOrder.isPending}
          style={{ padding: '8px 16px' }}
        >
          {placeOrder.isPending ? 'Đang xử lý…' : 'Xác nhận đăng ký'}
        </button>
        <Link to="/plans">Hủy</Link>
      </div>

      {placeOrder.isError && (
        <p style={{ color: 'crimson' }}>Tạo đơn thất bại — thử lại sau.</p>
      )}
    </section>
  );
}
