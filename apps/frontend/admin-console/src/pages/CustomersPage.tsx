import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { useState } from 'react';
import { api } from '../api/client';

interface Customer {
  id: string;
  name: string;
  email: string;
  phoneNumber?: string;
  status: string;
  createdAt: string;
}

export default function CustomersPage() {
  const qc = useQueryClient();
  const { data, isLoading, error } = useQuery({
    queryKey: ['customers'],
    queryFn: async () => {
      const res = await api.get<Customer[]>('/tmf-api/customerManagement/v4/customer?limit=50');
      return res.data;
    },
  });

  const [form, setForm] = useState({ name: '', email: '', phoneNumber: '' });

  const create = useMutation({
    mutationFn: async () => {
      // B-15 fix: customer-service now takes a CreateCustomerRequest DTO instead of the raw
      // entity, and that DTO has no `status` field — a new customer always starts
      // `Initialized` server-side (TMF629 lifecycle), it can't be created pre-activated by
      // whoever calls the API. Move it to Active from here via PATCH if you need that.
      const res = await api.post('/tmf-api/customerManagement/v4/customer', form);
      return res.data;
    },
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ['customers'] });
      setForm({ name: '', email: '', phoneNumber: '' });
    },
  });

  const remove = useMutation({
    mutationFn: async (id: string) => api.delete(`/tmf-api/customerManagement/v4/customer/${id}`),
    onSuccess: () => qc.invalidateQueries({ queryKey: ['customers'] }),
  });

  return (
    <section>
      <h1>Khách hàng</h1>

      <form
        onSubmit={(e) => { e.preventDefault(); create.mutate(); }}
        style={{ display: 'flex', gap: 8, marginBottom: 16, alignItems: 'baseline' }}
      >
        <input
          required placeholder="Tên"
          value={form.name} onChange={(e) => setForm({ ...form, name: e.target.value })}
        />
        <input
          required type="email" placeholder="Email"
          value={form.email} onChange={(e) => setForm({ ...form, email: e.target.value })}
        />
        <input
          placeholder="SĐT"
          value={form.phoneNumber} onChange={(e) => setForm({ ...form, phoneNumber: e.target.value })}
        />
        <button disabled={create.isPending}>Thêm</button>
        {create.isError && <span style={{ color: 'crimson' }}>Lỗi: trùng email hoặc dữ liệu không hợp lệ</span>}
      </form>

      {isLoading && <p>Đang tải…</p>}
      {error && <p>Lỗi tải danh sách.</p>}
      {data && (
        <table style={{ width: '100%', borderCollapse: 'collapse' }}>
          <thead>
            <tr>
              <th align="left">Tên</th>
              <th align="left">Email</th>
              <th align="left">SĐT</th>
              <th align="left">Status</th>
              <th align="left">Created</th>
              <th></th>
            </tr>
          </thead>
          <tbody>
            {data.map((c) => (
              <tr key={c.id} style={{ borderTop: '1px solid #eee' }}>
                <td>{c.name}</td>
                <td>{c.email}</td>
                <td>{c.phoneNumber || '—'}</td>
                <td>{c.status}</td>
                <td>{new Date(c.createdAt).toLocaleDateString('vi-VN')}</td>
                <td>
                  <button
                    onClick={() => { if (confirm(`Xóa ${c.name}?`)) remove.mutate(c.id); }}
                    style={{ background: '#cc0000', borderColor: '#cc0000' }}
                  >
                    Xóa
                  </button>
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      )}
    </section>
  );
}
