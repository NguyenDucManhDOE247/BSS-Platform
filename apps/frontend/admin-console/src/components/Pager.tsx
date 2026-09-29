/** Phân trang theo offset/limit (quy ước REST của repo) dựa trên tổng thật từ `X-Total-Count`. */
export default function Pager({ offset, limit, total, onChange }: {
  offset: number; limit: number; total: number; onChange: (offset: number) => void;
}) {
  if (total === 0) return null;
  const page = Math.floor(offset / limit) + 1;
  const pages = Math.max(1, Math.ceil(total / limit));
  return (
    <div style={{ display: 'flex', gap: 8, alignItems: 'baseline', marginTop: 12 }}>
      <button disabled={offset === 0} onClick={() => onChange(Math.max(0, offset - limit))}>← Trước</button>
      <span data-testid="pager">Trang {page}/{pages} · {total} bản ghi</span>
      <button disabled={offset + limit >= total} onClick={() => onChange(offset + limit)}>Sau →</button>
    </div>
  );
}
