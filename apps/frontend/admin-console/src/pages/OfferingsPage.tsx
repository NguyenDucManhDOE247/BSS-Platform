import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { useState } from 'react';
import { api, fetchPage, formatVND, problemDetail } from '../api/client';
import Pager from '../components/Pager';

interface ProductOffering {
  id: string;
  name: string;
  description?: string;
  categoryId?: string;
  priceAmount: number;
  priceCurrency: string;
  lifecycleStatus: string;
  recurringPeriod: string;
}

interface Category {
  id: string;
  name: string;
}

const URL = '/tmf-api/productCatalog/v4/productOffering';
const LIMIT = 20;
const PERIOD: Record<string, string> = { monthly: 'tháng', yearly: 'năm', one_time: 'một lần' };
const MERGE_PATCH = { headers: { 'Content-Type': 'application/merge-patch+json' } };

/** 1 dòng gói cước, có chế độ sửa giá/mô tả tại chỗ. */
function OfferingRow({ o, categoryName }: { o: ProductOffering; categoryName?: string }) {
  const qc = useQueryClient();
  const [editing, setEditing] = useState(false);
  const [price, setPrice] = useState(String(o.priceAmount));
  const [description, setDescription] = useState(o.description ?? '');

  const patch = useMutation({
    mutationFn: async (body: Partial<Pick<ProductOffering, 'priceAmount' | 'description' | 'lifecycleStatus'>>) =>
      api.patch(`${URL}/${o.id}`, body, MERGE_PATCH),
    onSuccess: () => { setEditing(false); qc.invalidateQueries({ queryKey: ['offerings'] }); },
  });

  // "Ngừng bán" = Retired, không xóa: đơn cũ vẫn tham chiếu được gói và giữ nguyên giá lúc mua (ADR-008).
  const retired = o.lifecycleStatus === 'Retired';

  return (
    <tr data-testid={`offering-${o.name}`} style={{ borderTop: '1px solid #eee', opacity: retired ? 0.6 : 1 }}>
      <td><strong>{o.name}</strong><br /><small style={{ color: '#666' }}>{categoryName ?? '—'}</small></td>
      <td>
        {editing
          ? <input aria-label="Mô tả" value={description} onChange={(e) => setDescription(e.target.value)} style={{ width: '100%' }} />
          : o.description}
      </td>
      <td align="right">
        {editing
          ? <input aria-label="Giá mới" type="number" min={0} value={price} onChange={(e) => setPrice(e.target.value)} style={{ width: 110 }} />
          : <>{formatVND(o.priceAmount)} <small>/{PERIOD[o.recurringPeriod] ?? o.recurringPeriod}</small></>}
      </td>
      <td data-testid="lifecycle">{o.lifecycleStatus}</td>
      <td style={{ display: 'flex', gap: 6 }}>
        {editing ? (
          <>
            <button
              disabled={patch.isPending || price === ''}
              onClick={() => patch.mutate({ priceAmount: Number(price), description })}
            >
              Lưu
            </button>
            <button onClick={() => setEditing(false)} style={{ background: '#888', borderColor: '#888' }}>Hủy</button>
          </>
        ) : (
          <>
            <button onClick={() => setEditing(true)}>Sửa</button>
            <button
              disabled={patch.isPending}
              onClick={() => patch.mutate({ lifecycleStatus: retired ? 'Active' : 'Retired' })}
              style={retired ? undefined : { background: '#cc0000', borderColor: '#cc0000' }}
            >
              {retired ? 'Bán lại' : 'Ngừng bán'}
            </button>
          </>
        )}
        {patch.isError && <small style={{ color: 'crimson' }}>{problemDetail(patch.error, 'Lưu thất bại')}</small>}
      </td>
    </tr>
  );
}

const EMPTY_FORM = { name: '', description: '', priceAmount: '', recurringPeriod: 'monthly', categoryId: '' };

export default function OfferingsPage() {
  const qc = useQueryClient();
  const [offset, setOffset] = useState(0);

  // Admin thấy mọi gói kể cả Retired (server quyết theo role — ADR-008); khách chỉ thấy gói đang bán.
  const offerings = useQuery({
    queryKey: ['offerings', offset],
    queryFn: () => fetchPage<ProductOffering>(URL, { offset, limit: LIMIT }),
  });

  const categories = useQuery({
    queryKey: ['categories'],
    queryFn: async () => (await api.get<Category[]>('/tmf-api/productCatalog/v4/category')).data,
  });
  const categoryName = (id?: string) => categories.data?.find((c) => c.id === id)?.name;

  const [form, setForm] = useState(EMPTY_FORM);
  const create = useMutation({
    mutationFn: async () => (await api.post(URL, {
      name: form.name,
      description: form.description || undefined,
      priceAmount: Number(form.priceAmount),
      priceCurrency: 'VND',
      recurringPeriod: form.recurringPeriod,
      categoryId: form.categoryId || undefined,
    })).data,
    onSuccess: () => { setForm(EMPTY_FORM); qc.invalidateQueries({ queryKey: ['offerings'] }); },
  });

  return (
    <section>
      <h1>Gói cước (TMF620)</h1>

      <h2 style={{ fontSize: '1.1rem' }}>Tạo gói mới</h2>
      <form
        onSubmit={(e) => { e.preventDefault(); create.mutate(); }}
        style={{ display: 'flex', gap: 8, flexWrap: 'wrap', alignItems: 'baseline', marginBottom: 24 }}
      >
        <input required aria-label="Tên gói" placeholder="Tên gói" value={form.name} onChange={(e) => setForm({ ...form, name: e.target.value })} />
        <input aria-label="Mô tả gói" placeholder="Mô tả" value={form.description} onChange={(e) => setForm({ ...form, description: e.target.value })} />
        <input
          required aria-label="Giá (VND)" type="number" min={0} placeholder="Giá (VND)"
          value={form.priceAmount} onChange={(e) => setForm({ ...form, priceAmount: e.target.value })}
        />
        <select aria-label="Chu kỳ" value={form.recurringPeriod} onChange={(e) => setForm({ ...form, recurringPeriod: e.target.value })}>
          {Object.entries(PERIOD).map(([v, label]) => <option key={v} value={v}>{label}</option>)}
        </select>
        <select aria-label="Danh mục" value={form.categoryId} onChange={(e) => setForm({ ...form, categoryId: e.target.value })}>
          <option value="">(không danh mục)</option>
          {categories.data?.map((c) => <option key={c.id} value={c.id}>{c.name}</option>)}
        </select>
        <button disabled={create.isPending}>Tạo gói</button>
        {create.isError && <span style={{ color: 'crimson' }}>{problemDetail(create.error, 'Tạo gói thất bại')}</span>}
      </form>

      {offerings.isLoading && <p>Đang tải…</p>}
      {offerings.error && <p style={{ color: 'crimson' }}>Lỗi tải danh sách gói.</p>}
      {offerings.data && (
        <table style={{ width: '100%', borderCollapse: 'collapse' }}>
          <thead>
            <tr>
              <th align="left">Tên</th>
              <th align="left">Mô tả</th>
              <th align="right">Giá</th>
              <th align="left">Trạng thái</th>
              <th></th>
            </tr>
          </thead>
          <tbody>
            {offerings.data.rows.map((o) => <OfferingRow key={o.id} o={o} categoryName={categoryName(o.categoryId)} />)}
          </tbody>
        </table>
      )}
      {offerings.data && <Pager offset={offset} limit={LIMIT} total={offerings.data.total} onChange={setOffset} />}
    </section>
  );
}
