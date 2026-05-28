import { useQuery } from '@tanstack/react-query';
import axios from 'axios';
import { Link } from 'react-router-dom';

interface ProductOffering {
  id: string;
  name: string;
  description?: string;
  categoryId?: string;
  priceAmount: number;
  priceCurrency: string;
  recurringPeriod: 'monthly' | 'yearly' | 'one_time';
  lifecycleStatus: string;
}

const formatPrice = (amount: number, currency: string) =>
  new Intl.NumberFormat('vi-VN', { style: 'currency', currency }).format(amount);

const periodLabel: Record<ProductOffering['recurringPeriod'], string> = {
  monthly: '/tháng',
  yearly: '/năm',
  one_time: '',
};

export default function PlansPage() {
  const { data, isLoading, error } = useQuery({
    queryKey: ['offerings'],
    queryFn: async () => {
      const res = await axios.get<ProductOffering[]>(
        '/api/tmf-api/productCatalog/v4/productOffering?lifecycleStatus=Active&limit=50',
      );
      return res.data;
    },
  });

  if (isLoading) return <p>Đang tải các gói cước…</p>;
  if (error) return <p>Lỗi khi tải danh sách gói cước.</p>;
  if (!data?.length) return <p>Hiện chưa có gói cước nào.</p>;

  return (
    <section>
      <h1>Các gói cước</h1>
      <div className="plan-grid">
        {data.map((p) => (
          <article key={p.id} className="plan-card">
            <h2>{p.name}</h2>
            <p className="plan-card__price">
              {formatPrice(p.priceAmount, p.priceCurrency)}
              <span>{periodLabel[p.recurringPeriod]}</span>
            </p>
            {p.description && <p>{p.description}</p>}
            <Link to={`/order/${p.id}`}>Đăng ký →</Link>
          </article>
        ))}
      </div>
    </section>
  );
}
