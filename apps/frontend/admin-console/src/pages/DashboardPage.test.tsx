import { QueryClient, QueryClientProvider } from '@tanstack/react-query';
import { render, screen, waitFor } from '@testing-library/react';
import { MemoryRouter } from 'react-router-dom';
import { describe, expect, it, vi } from 'vitest';
import DashboardPage from './DashboardPage';

// Giai đoạn 9 việc 5: số trên Dashboard là TỔNG THẬT từ server (X-Total-Count / API summary), không
// phải số phần tử của 1 trang. Mock đúng lớp HTTP — tổng 250 > limit cũ 100 để bắt đúng bug cũ.
const totals: Record<string, number> = {
  '/tmf-api/customerManagement/v4/customer': 250,
  '/tmf-api/productCatalog/v4/productOffering': 7,
  '/tmf-api/orderManagement/v4/productOrder': 42,
};

vi.mock('../api/client', async (importOriginal) => ({
  ...(await importOriginal<typeof import('../api/client')>()),
  fetchPage: vi.fn(async (url: string, params: Record<string, unknown>) => ({
    rows: [],
    total: params.status === 'Initialized' ? 3 : totals[url],
  })),
  api: {
    get: vi.fn(async () => ({ data: { invoiceCount: 42, totalAmount: 4620000, totalTax: 420000, currency: 'VND' } })),
  },
}));

function renderPage() {
  return render(
    <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
      <MemoryRouter><DashboardPage /></MemoryRouter>
    </QueryClientProvider>,
  );
}

describe('DashboardPage', () => {
  it('shows real totals from the server, not the length of one page', async () => {
    renderPage();
    expect(screen.getByRole('heading', { name: /admin dashboard/i })).toBeDefined();

    await waitFor(() => expect(screen.getByTestId('tile-Khách hàng').textContent).toContain('250'));
    expect(screen.getByTestId('tile-Chờ duyệt').textContent).toContain('3');
    expect(screen.getByTestId('tile-Gói cước').textContent).toContain('7');
    expect(screen.getByTestId('tile-Đơn hàng').textContent).toContain('42');
  });

  it('shows revenue summed by the server (including VAT)', async () => {
    renderPage();
    await waitFor(() => expect(screen.getByTestId('tile-Doanh thu (gồm VAT)').textContent).toMatch(/4\.620\.000/));
    expect(screen.getByTestId('tile-Hóa đơn').textContent).toContain('42');
  });

  it('pending-approval tile links to the filtered customer list', async () => {
    renderPage();
    const link = screen.getByTestId('tile-Chờ duyệt').closest('a');
    expect(link?.getAttribute('href')).toBe('/customers?status=Initialized');
  });
});
