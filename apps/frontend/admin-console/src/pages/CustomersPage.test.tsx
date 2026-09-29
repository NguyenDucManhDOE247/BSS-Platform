import { QueryClient, QueryClientProvider } from '@tanstack/react-query';
import { fireEvent, render, screen, waitFor, within } from '@testing-library/react';
import { MemoryRouter } from 'react-router-dom';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { api, fetchPage } from '../api/client';
import CustomersPage, { type Customer } from './CustomersPage';

// Giai đoạn 9 việc 5 — admin duyệt/khóa khách (ADR-008 quyết định 3). Mock lớp HTTP; kiểm đúng
// request mà nút gửi đi (PATCH merge-patch với status đích) — backend mới là nơi chặn thật.
const rows: Customer[] = [
  { id: 'c-new', name: 'Khach Moi', email: 'moi@x.vn', status: 'Initialized', selfRegistered: true, createdAt: '2026-09-28T00:00:00Z' },
  { id: 'c-act', name: 'Khach Active', email: 'act@x.vn', status: 'Active', createdAt: '2026-09-28T00:00:00Z' },
  { id: 'c-sus', name: 'Khach Khoa', email: 'sus@x.vn', status: 'Suspended', createdAt: '2026-09-28T00:00:00Z' },
];

vi.mock('../api/client', async (importOriginal) => ({
  ...(await importOriginal<typeof import('../api/client')>()),
  fetchPage: vi.fn(async () => ({ rows, total: 45 })),
  api: { patch: vi.fn(async () => ({ data: {} })), delete: vi.fn(), post: vi.fn(), get: vi.fn() },
}));

function renderPage(url = '/customers') {
  return render(
    <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
      <MemoryRouter initialEntries={[url]}><CustomersPage /></MemoryRouter>
    </QueryClientProvider>,
  );
}

const row = (email: string) => screen.getByTestId(`customer-${email}`);

describe('CustomersPage', () => {
  beforeEach(() => { vi.clearAllMocks(); });

  it('offers the right action per status: approve / lock / unlock', async () => {
    renderPage();
    await waitFor(() => row('moi@x.vn'));
    expect(within(row('moi@x.vn')).getByRole('button', { name: 'Duyệt' })).toBeDefined();
    expect(within(row('act@x.vn')).getByRole('button', { name: 'Khóa' })).toBeDefined();
    expect(within(row('sus@x.vn')).getByRole('button', { name: 'Mở khóa' })).toBeDefined();
  });

  it('approving sends a merge-patch that moves the customer to Active', async () => {
    renderPage();
    await waitFor(() => row('moi@x.vn'));
    fireEvent.click(within(row('moi@x.vn')).getByRole('button', { name: 'Duyệt' }));
    await waitFor(() => expect(api.patch).toHaveBeenCalledWith(
      '/tmf-api/customerManagement/v4/customer/c-new',
      { status: 'Active' },
      { headers: { 'Content-Type': 'application/merge-patch+json' } },
    ));
  });

  it('locking an active customer moves it to Suspended', async () => {
    renderPage();
    await waitFor(() => row('act@x.vn'));
    fireEvent.click(within(row('act@x.vn')).getByRole('button', { name: 'Khóa' }));
    await waitFor(() => expect(api.patch).toHaveBeenCalledWith(
      '/tmf-api/customerManagement/v4/customer/c-act', { status: 'Suspended' }, expect.anything(),
    ));
  });

  it('reads filters from the URL and paginates on the real total', async () => {
    renderPage('/customers?status=Initialized&q=moi');
    await waitFor(() => screen.getByTestId('pager'));
    expect(fetchPage).toHaveBeenCalledWith(
      '/tmf-api/customerManagement/v4/customer',
      { status: 'Initialized', q: 'moi', offset: 0, limit: 20 },
    );
    expect(screen.getByTestId('pager').textContent).toContain('Trang 1/3');

    fireEvent.click(screen.getByRole('button', { name: /sau/i }));
    await waitFor(() => expect(fetchPage).toHaveBeenLastCalledWith(
      '/tmf-api/customerManagement/v4/customer',
      { status: 'Initialized', q: 'moi', offset: 20, limit: 20 },
    ));
  });
});
