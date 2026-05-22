import { useQuery } from '@tanstack/react-query';
import axios from 'axios';

interface Plan {
  id: string;
  name: string;
  price: string;
}

export default function PlansPage() {
  const { data, isLoading, error } = useQuery({
    queryKey: ['plans'],
    queryFn: async () => {
      const res = await axios.get<Plan[]>('/api/tmf-api/productCatalog/v4/catalog');
      return res.data;
    },
  });

  if (isLoading) return <p>Loading…</p>;
  if (error) return <p>Error loading plans.</p>;

  return (
    <section>
      <h1>Plans</h1>
      <pre>{JSON.stringify(data, null, 2)}</pre>
    </section>
  );
}
