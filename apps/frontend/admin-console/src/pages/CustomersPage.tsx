import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { useState } from 'react';
import { Link, useSearchParams } from 'react-router-dom';
import { api, fetchPage, problemDetail } from '../api/client';
import Pager from '../components/Pager';

export interface Customer {
  id: string;
  name: string;
  email: string;
  phoneNumber?: string;
  status: CustomerStatus;
  selfRegistered?: boolean;
  createdAt: string;
}

type CustomerStatus = 'Initialized' | 'Validated' | 'Active' | 'Suspended' | 'Terminated';

const URL = '/tmf-api/customerManagement/v4/customer';
const LIMIT = 20;
const STATUSES: CustomerStatus[] = ['Initialized', 'Validated', 'Active', 'Suspended', 'Terminated'];

/**
 * Hành động hợp lệ theo trạng thái (ADR-008 quyết định 3): duyệt = `→ Active` (mới được mua gói);
 * khóa = `Active → Suspended` (chặn đặt hàng, vẫn xem được hóa đơn cũ); mở khóa = `Suspended → Active`.
 */
function actionFor(status: CustomerStatus): { label: string; to: CustomerStatus } | null {
  switch (status) {
    case 'Initialized':
    case 'Validated': return { label: 'Duyệt', to: 'Active' };
    case 'Active': return { label: 'Khóa', to: 'Suspended' };
    case 'Suspended': return { label: 'Mở khóa', to: 'Active' };
    default: return null;
  }
}

export default function CustomersPage() {
  const qc = useQueryClient();
  // Bộ lọc nằm trên URL → Dashboard link thẳng được tới "Chờ duyệt", F5 không mất bộ lọc.
  const [params, setParams] = useSearchParams();
  const status = params.get('status') ?? '';
  const q = params.get('q') ?? '';
  const offset = Number(params.get('offset') ?? 0);
  const [search, setSearch] = useState(q);

  const update = (changes: Record<string, string>) => {
    const next = new URLSearchParams(params);
    for (const [k, v] of Object.entries(changes)) { if (v) next.set(k, v); else next.delete(k); }
    if (!('offset' in changes)) next.delete('offset'); // đổi bộ lọc → về trang 1
    setParams(next);
  };

  const list = useQuery({
    queryKey: ['customers', status, q, offset],
    queryFn: () => fetchPage<Customer>(URL, { status, q, offset, limit: LIMIT }),
  });

  const refresh = () => qc.invalidateQueries({ queryKey: ['customers'] });

  const changeStatus = useMutation({
    mutationFn: async ({ id, to }: { id: string; to: CustomerStatus }) =>
      api.patch(`${URL}/${id}`, { status: to }, { headers: { 'Content-Type': 'application/merge-patch+json' } }),
    onSuccess: refresh,
  });

  const remove = useMutation({
    mutationFn: async (id: string) => api.delete(`${URL}/${id}`),
    onSuccess: refresh,
  });

  const [form, setForm] = useState({ name: '', email: '', phoneNumber: '' });
  const create = useMutation({
    // Khách tạo tay ở đây bắt đầu `Initialized` như khách tự đăng ký (server quyết định, không nhận
    // `status` từ request — B-15) và không gắn tài khoản Keycloak nào.
    mutationFn: async () => (await api.post(URL, form)).data,
    onSuccess: () => { refresh(); setForm({ name: '', email: '', phoneNumber: '' }); },
  });

  return (
    <section>
      <h1>Khách hàng</h1>

      <form
        onSubmit={(e) => { e.preventDefault(); update({ q: search.trim() }); }}
        style={{ display: 'flex', gap: 8, marginBottom: 12, alignItems: 'baseline' }}
      >
        <input
          aria-label="Tìm khách" placeholder="Tìm theo tên hoặc email"
          value={search} onChange={(e) => setSearch(e.target.value)} style={{ minWidth: 260 }}
        />
        <button>Tìm</button>
        <select aria-label="Trạng thái" value={status} onChange={(e) => update({ status: e.target.value })}>
          <option value="">Mọi trạng thái</option>
          {STATUSES.map((s) => <option key={s} value={s}>{s}</option>)}
        </select>
      </form>

      {list.isLoading && <p>Đang tải…</p>}
      {list.error && <p style={{ color: 'crimson' }}>Lỗi tải danh sách.</p>}
      {changeStatus.isError && (
        <p style={{ color: 'crimson' }}>{problemDetail(changeStatus.error, 'Đổi trạng thái thất bại.')}</p>
      )}
      {list.data && list.data.rows.length === 0 && <p>Không có khách nào khớp bộ lọc.</p>}
      {list.data && list.data.rows.length > 0 && (
        <table style={{ width: '100%', borderCollapse: 'collapse' }}>
          <thead>
            <tr>
              <th align="left">Tên</th>
              <th align="left">Email</th>
              <th align="left">SĐT</th>
              <th align="left">Trạng thái</th>
              <th align="left">Tạo lúc</th>
              <th align="left">Xem</th>
              <th></th>
            </tr>
          </thead>
          <tbody>
            {list.data.rows.map((c) => {
              const action = actionFor(c.status);
              return (
                <tr key={c.id} data-testid={`customer-${c.email}`} style={{ borderTop: '1px solid #eee' }}>
                  <td>{c.name}{c.selfRegistered && <small title="Tự đăng ký qua web-portal"> 🌐</small>}</td>
                  <td>{c.email}</td>
                  <td>{c.phoneNumber || '—'}</td>
                  <td data-testid="status">{c.status}</td>
                  <td>{new Date(c.createdAt).toLocaleDateString('vi-VN')}</td>
                  <td>
                    <Link to={`/orders?customerId=${c.id}`}>Đơn</Link>{' · '}
                    <Link to={`/bills?customerId=${c.id}`}>Hóa đơn</Link>
                  </td>
                  <td style={{ display: 'flex', gap: 6 }}>
                    {action && (
                      <button
                        disabled={changeStatus.isPending}
                        onClick={() => changeStatus.mutate({ id: c.id, to: action.to })}
                        style={action.to === 'Suspended' ? { background: '#e67e22', borderColor: '#e67e22' } : undefined}
                      >
                        {action.label}
                      </button>
                    )}
                    <button
                      onClick={() => { if (confirm(`Xóa ${c.name}?`)) remove.mutate(c.id); }}
                      style={{ background: '#cc0000', borderColor: '#cc0000' }}
                    >
                      Xóa
                    </button>
                  </td>
                </tr>
              );
            })}
          </tbody>
        </table>
      )}
      {list.data && (
        <Pager offset={offset} limit={LIMIT} total={list.data.total} onChange={(o) => update({ offset: String(o) })} />
      )}

      <h2 style={{ fontSize: '1.1rem', marginTop: 32 }}>Thêm khách tại quầy</h2>
      <form
        onSubmit={(e) => { e.preventDefault(); create.mutate(); }}
        style={{ display: 'flex', gap: 8, alignItems: 'baseline' }}
      >
        <input required placeholder="Tên" value={form.name} onChange={(e) => setForm({ ...form, name: e.target.value })} />
        <input
          required type="email" placeholder="Email"
          value={form.email} onChange={(e) => setForm({ ...form, email: e.target.value })}
        />
        <input placeholder="SĐT" value={form.phoneNumber} onChange={(e) => setForm({ ...form, phoneNumber: e.target.value })} />
        <button disabled={create.isPending}>Thêm</button>
        {create.isError && (
          <span style={{ color: 'crimson' }}>{problemDetail(create.error, 'Trùng email hoặc dữ liệu không hợp lệ')}</span>
        )}
      </form>
    </section>
  );
}
