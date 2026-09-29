import { render, screen } from '@testing-library/react';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import AdminGate from './AdminGate';

// Access token giả (chữ ký không quan trọng — giao diện chỉ đọc payload để quyết định HIỂN THỊ; kiểm
// chữ ký là việc của backend). Payload base64url như Keycloak phát ra.
function fakeToken(roles: string[]): string {
  const b64url = (o: object) => btoa(JSON.stringify(o)).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
  return `${b64url({ alg: 'RS256' })}.${b64url({ realm_access: { roles } })}.sig`;
}

const authState: {
  isLoading: boolean; isAuthenticated: boolean; error?: Error;
  user?: { access_token: string; profile: { preferred_username: string } };
  signinRedirect: () => Promise<void>; signoutRedirect: () => Promise<void>;
} = { isLoading: false, isAuthenticated: false, signinRedirect: vi.fn(), signoutRedirect: vi.fn() };
vi.mock('react-oidc-context', () => ({ useAuth: () => authState }));

const renderGate = () => render(<AdminGate><h1>Trang quản trị</h1></AdminGate>);

describe('AdminGate', () => {
  beforeEach(() => {
    authState.isAuthenticated = false;
    authState.user = undefined;
  });

  it('not logged in → login button, no admin content', () => {
    renderGate();
    expect(screen.getByRole('button', { name: 'Đăng nhập' })).toBeDefined();
    expect(screen.queryByRole('heading', { name: 'Trang quản trị' })).toBeNull();
  });

  it('logged in as a customer (no admin role) → access denied, no admin content', () => {
    authState.isAuthenticated = true;
    authState.user = { access_token: fakeToken(['customer']), profile: { preferred_username: 'customer1' } };
    renderGate();
    expect(screen.getByTestId('not-admin').textContent).toContain('customer1');
    expect(screen.queryByRole('heading', { name: 'Trang quản trị' })).toBeNull();
  });

  it('logged in with the admin realm role → admin content', () => {
    authState.isAuthenticated = true;
    authState.user = { access_token: fakeToken(['admin', 'offline_access']), profile: { preferred_username: 'admin1' } };
    renderGate();
    expect(screen.getByRole('heading', { name: 'Trang quản trị' })).toBeDefined();
  });

  it('garbage token → treated as not admin (never throws)', () => {
    authState.isAuthenticated = true;
    authState.user = { access_token: 'not-a-jwt', profile: { preferred_username: 'x' } };
    renderGate();
    expect(screen.getByTestId('not-admin')).toBeDefined();
  });
});
