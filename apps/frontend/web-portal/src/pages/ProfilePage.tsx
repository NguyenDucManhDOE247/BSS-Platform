import { useMutation, useQueryClient } from '@tanstack/react-query';
import { useEffect, useState } from 'react';
import { api, problemDetail } from '../api/client';
import { statusText, useMyProfile } from '../hooks/useMyProfile';

/**
 * Giai đoạn 9 việc 4 (ADR-008 quyết định 3): lần đầu đăng nhập → khách tự tạo hồ sơ (họ tên, SĐT;
 * email lấy từ tài khoản đăng nhập, không sửa được ở đây) → trạng thái "chờ duyệt" cho tới khi nhân
 * viên duyệt trên admin-console.
 */
export default function ProfilePage() {
  const qc = useQueryClient();
  const { data: me, isLoading, error } = useMyProfile();
  const [form, setForm] = useState({ name: '', phoneNumber: '' });

  useEffect(() => {
    if (me) setForm({ name: me.name, phoneNumber: me.phoneNumber ?? '' });
  }, [me]);

  const save = useMutation({
    mutationFn: async () => {
      const body = { name: form.name, phoneNumber: form.phoneNumber || undefined };
      return me
        ? api.patch('/tmf-api/customerManagement/v4/customer/me', body, {
            headers: { 'Content-Type': 'application/merge-patch+json' },
          })
        : api.post('/tmf-api/customerManagement/v4/customer/me', body);
    },
    onSuccess: () => qc.invalidateQueries({ queryKey: ['me'] }),
  });

  if (isLoading) return <p>Đang tải hồ sơ…</p>;
  if (error) return <p style={{ color: 'crimson' }}>{problemDetail(error, 'Lỗi khi tải hồ sơ.')}</p>;

  return (
    <section>
      <h1>{me ? 'Hồ sơ của tôi' : 'Hoàn tất hồ sơ khách hàng'}</h1>
      {me ? (
        <p>
          <strong>Email:</strong> {me.email} · <strong>Trạng thái:</strong>{' '}
          <span data-testid="status">{me.status}</span> — {statusText[me.status]}
        </p>
      ) : (
        <p>Bạn đã có tài khoản đăng nhập. Điền thông tin dưới đây để tạo hồ sơ khách hàng.</p>
      )}

      <form
        onSubmit={(e) => { e.preventDefault(); save.mutate(); }}
        style={{ display: 'grid', gap: 8, maxWidth: 360, marginTop: 12 }}
      >
        <label>
          Họ tên
          <input required value={form.name} onChange={(e) => setForm({ ...form, name: e.target.value })} />
        </label>
        <label>
          Số điện thoại
          <input value={form.phoneNumber} onChange={(e) => setForm({ ...form, phoneNumber: e.target.value })} />
        </label>
        <button disabled={save.isPending}>{me ? 'Lưu thay đổi' : 'Tạo hồ sơ'}</button>
        {save.isSuccess && <span style={{ color: 'green' }}>Đã lưu.</span>}
        {save.isError && <span style={{ color: 'crimson' }}>{problemDetail(save.error, 'Lưu thất bại.')}</span>}
      </form>
    </section>
  );
}
