import { useQuery } from '@tanstack/react-query';
import { useState } from 'react';
import { api } from '../api/client';
import type { Customer } from '../pages/CustomersPage';

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/**
 * Lọc danh sách Đơn hàng/Hóa đơn theo 1 khách (`?customerId=` — tham số server hỗ trợ sẵn cho admin).
 * Thường đi tới từ link "Đơn · Hóa đơn" ở trang Khách hàng; khi đang lọc thì hiện tên khách cho dễ đọc.
 */
export default function CustomerFilter({ customerId, onChange }: {
  customerId: string; onChange: (customerId: string) => void;
}) {
  const [draft, setDraft] = useState(customerId);
  const customer = useQuery({
    queryKey: ['customer', customerId],
    enabled: UUID_RE.test(customerId),
    queryFn: async () => (await api.get<Customer>(`/tmf-api/customerManagement/v4/customer/${customerId}`)).data,
  });
  const invalid = draft.trim() !== '' && !UUID_RE.test(draft.trim());

  return (
    <div style={{ marginBottom: 12 }}>
      <form
        onSubmit={(e) => { e.preventDefault(); if (!invalid) onChange(draft.trim()); }}
        style={{ display: 'flex', gap: 8, alignItems: 'baseline' }}
      >
        <input
          aria-label="Mã khách hàng" placeholder="Lọc theo mã khách hàng (UUID)"
          value={draft} onChange={(e) => setDraft(e.target.value)} style={{ minWidth: 340 }}
        />
        <button disabled={invalid}>Lọc</button>
        {customerId && (
          <button type="button" onClick={() => { setDraft(''); onChange(''); }} style={{ background: '#888', borderColor: '#888' }}>
            Bỏ lọc
          </button>
        )}
        {invalid && <small style={{ color: 'crimson' }}>Mã khách hàng phải là UUID.</small>}
      </form>
      {customerId && (
        <p data-testid="filter-customer" style={{ margin: '8px 0 0', color: '#444' }}>
          Đang xem của khách: <strong>{customer.data ? `${customer.data.name} (${customer.data.email})` : customerId}</strong>
        </p>
      )}
    </div>
  );
}
