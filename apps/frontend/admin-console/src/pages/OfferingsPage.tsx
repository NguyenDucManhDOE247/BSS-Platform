import { useQuery } from '@tanstack/react-query';
import { api, formatVND } from '../api/client';

interface ProductOffering {
  id: string;
  name: string;
  description?: string;
  priceAmount: number;
  priceCurrency: string;
  lifecycleStatus: string;
  recurringPeriod: string;
}

interface Category {
  id: string;
  name: string;
}

export default function OfferingsPage() {
  const offerings = useQuery({
    queryKey: ['offerings-all'],
    queryFn: async () => (await api.get<ProductOffering[]>(
      '/tmf-api/productCatalog/v4/productOffering?limit=100',
    )).data,
  });

  const categories = useQuery({
    queryKey: ['categories'],
    queryFn: async () => (await api.get<Category[]>('/tmf-api/productCatalog/v4/category')).data,
  });

  return (
    <section>
      <h1>Catalog (TMF620)</h1>

      <h2 style={{ fontSize: '1.1rem' }}>Categories ({categories.data?.length ?? 0})</h2>
      <ul>
        {categories.data?.map((c) => <li key={c.id}>{c.name}</li>)}
      </ul>

      <h2 style={{ fontSize: '1.1rem' }}>Offerings ({offerings.data?.length ?? 0})</h2>
      <table style={{ width: '100%', borderCollapse: 'collapse' }}>
        <thead>
          <tr>
            <th align="left">Tên</th>
            <th align="left">Mô tả</th>
            <th align="right">Giá</th>
            <th align="left">Status</th>
          </tr>
        </thead>
        <tbody>
          {offerings.data?.map((o) => (
            <tr key={o.id} style={{ borderTop: '1px solid #eee' }}>
              <td><strong>{o.name}</strong></td>
              <td>{o.description}</td>
              <td align="right">{formatVND(o.priceAmount)} <small>/{o.recurringPeriod === 'monthly' ? 'tháng' : o.recurringPeriod}</small></td>
              <td>{o.lifecycleStatus}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </section>
  );
}
