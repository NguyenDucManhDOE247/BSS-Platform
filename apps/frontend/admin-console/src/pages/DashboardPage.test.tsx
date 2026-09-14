import { QueryClient, QueryClientProvider } from '@tanstack/react-query';
import { render, screen } from '@testing-library/react';
import { describe, expect, it } from 'vitest';
import DashboardPage from './DashboardPage';

// B-04 fix — see web-portal/src/api/client.test.ts for why any test at all matters here.
// react-query needs a QueryClientProvider in the tree; the underlying axios calls it fires
// have nowhere real to land in jsdom, but that's fine — this test only asserts the loading
// ("…") render that happens synchronously, before those requests could resolve either way.
describe('DashboardPage', () => {
  it('renders the three metric tiles in a loading state', () => {
    const client = new QueryClient({
      defaultOptions: { queries: { retry: false } },
    });

    render(
      <QueryClientProvider client={client}>
        <DashboardPage />
      </QueryClientProvider>,
    );

    expect(screen.getByRole('heading', { name: /admin dashboard/i })).toBeDefined();
    expect(screen.getByText('Customers')).toBeDefined();
    expect(screen.getByText('Product Offerings')).toBeDefined();
    expect(screen.getByText('Billing Accounts')).toBeDefined();
  });
});
