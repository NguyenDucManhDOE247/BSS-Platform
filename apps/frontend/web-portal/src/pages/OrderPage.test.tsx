import { fireEvent, render, screen, waitFor } from '@testing-library/react';
import { QueryClient, QueryClientProvider } from '@tanstack/react-query';
import { MemoryRouter, Route, Routes } from 'react-router-dom';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import OrderPage from './OrderPage';
import { api } from '../api/client';
import type { MyProfile } from '../hooks/useMyProfile';

// Giai đoạn 9 việc 4: trang Đặt hàng phải chặn đúng người ở phía giao diện (backend cũng chặn — đây
// là trải nghiệm người dùng, không phải lớp bảo mật). Mock đúng 3 thứ nằm NGOÀI component: trạng thái
// đăng nhập, hồ sơ, và HTTP lấy gói cước.
const authState = { isAuthenticated: true, isLoading: false, signinRedirect: vi.fn() };
vi.mock('react-oidc-context', () => ({ useAuth: () => authState }));

let profile: MyProfile | null | undefined;
vi.mock('../hooks/useMyProfile', async (importOriginal) => ({
  ...(await importOriginal<typeof import('../hooks/useMyProfile')>()),
  useMyProfile: () => ({ data: profile, isLoading: false }),
}));

vi.mock('../api/client', async (importOriginal) => ({
  ...(await importOriginal<typeof import('../api/client')>()),
  api: {
    get: vi.fn(async () => ({ data: { id: 'off-1', name: 'Pro 80', priceAmount: 99000, priceCurrency: 'VND' } })),
    post: vi.fn(),
  },
}));

function renderPage() {
  return render(
    <QueryClientProvider client={new QueryClient()}>
      <MemoryRouter initialEntries={['/order/off-1']}>
        <Routes><Route path="/order/:offeringId" element={<OrderPage />} /></Routes>
      </MemoryRouter>
    </QueryClientProvider>,
  );
}

describe('OrderPage', () => {
  beforeEach(() => {
    authState.isAuthenticated = true;
    profile = undefined;
  });

  it('not logged in → offers login/register instead of an order button', async () => {
    authState.isAuthenticated = false;
    renderPage();
    await waitFor(() => screen.getByRole('button', { name: /đăng nhập để đăng ký gói/i }));
    expect(screen.queryByRole('button', { name: /xác nhận đăng ký/i })).toBeNull();
  });

  it('logged in but no customer profile yet → links to complete the profile', async () => {
    profile = null;
    renderPage();
    await waitFor(() => screen.getByRole('link', { name: /hoàn tất hồ sơ/i }));
    expect(screen.queryByRole('button', { name: /xác nhận đăng ký/i })).toBeNull();
  });

  it('profile awaiting approval → explains why and shows no order button', async () => {
    profile = { id: 'c1', name: 'A', email: 'a@x', status: 'Initialized' };
    renderPage();
    const msg = await waitFor(() => screen.getByTestId('not-active'));
    expect(msg.textContent).toMatch(/chờ nhân viên duyệt/i);
    expect(screen.queryByRole('button', { name: /xác nhận đăng ký/i })).toBeNull();
  });

  it('approved (Active) customer → can place the order', async () => {
    profile = { id: 'c1', name: 'A', email: 'a@x', status: 'Active' };
    renderPage();
    await waitFor(() => screen.getByRole('button', { name: /xác nhận đăng ký/i }));
  });

  it('retrying after a failure resends the SAME Idempotency-Key (B-15: no second order)', async () => {
    profile = { id: 'c1', name: 'A', email: 'a@x', status: 'Active' };
    const post = vi.mocked(api.post);
    post.mockReset();
    post.mockRejectedValueOnce(new Error('network down')).mockResolvedValueOnce({ data: { id: 'o-1' } });
    renderPage();

    const button = await waitFor(() => screen.getByRole('button', { name: /xác nhận đăng ký/i }));
    fireEvent.click(button);
    await waitFor(() => expect(post).toHaveBeenCalledTimes(1));
    await waitFor(() =>
      expect((screen.getByRole('button', { name: /xác nhận đăng ký/i }) as HTMLButtonElement).disabled).toBe(false));
    fireEvent.click(screen.getByRole('button', { name: /xác nhận đăng ký/i }));
    await waitFor(() => expect(post).toHaveBeenCalledTimes(2));

    const keyOf = (call: unknown[]) =>
      (call[2] as { headers: Record<string, string> }).headers['Idempotency-Key'];
    expect(keyOf(post.mock.calls[0])).toMatch(/\S+/);
    expect(keyOf(post.mock.calls[1])).toBe(keyOf(post.mock.calls[0]));
  });
});
