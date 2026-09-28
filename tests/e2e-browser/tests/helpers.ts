import type { APIRequestContext, Page } from '@playwright/test';

/**
 * Thao tác "phía nhân viên" chưa có UI (duyệt khách) — gọi API thật qua gateway bằng token admin thật.
 * Khi admin-console có trang duyệt (GĐ9 việc 5), test sẽ chuyển sang bấm UI thay cho hàm này.
 */
export async function adminToken(request: APIRequestContext, baseURL: string): Promise<string> {
  const res = await request.post(`${baseURL}/auth/realms/bss/protocol/openid-connect/token`, {
    form: { grant_type: 'password', client_id: 'api-gateway', username: 'admin1', password: 'admin1pass' },
  });
  if (!res.ok()) throw new Error(`Lấy token admin thất bại: ${res.status()} ${await res.text()}`);
  return (await res.json()).access_token as string;
}

export async function approveCustomerByEmail(
  request: APIRequestContext, baseURL: string, email: string,
): Promise<void> {
  const token = await adminToken(request, baseURL);
  const auth = { Authorization: `Bearer ${token}` };
  const list = await request.get(
    `${baseURL}/api/tmf-api/customerManagement/v4/customer?status=Initialized&q=${encodeURIComponent(email)}`,
    { headers: auth },
  );
  const customers = (await list.json()) as { id: string; email: string }[];
  const target = customers.find((c) => c.email === email);
  if (!target) throw new Error(`Không thấy khách ${email} trong danh sách chờ duyệt`);
  const res = await request.patch(`${baseURL}/api/tmf-api/customerManagement/v4/customer/${target.id}`, {
    headers: { ...auth, 'Content-Type': 'application/merge-patch+json' },
    data: { status: 'Active' },
  });
  if (!res.ok()) throw new Error(`Duyệt thất bại: ${res.status()} ${await res.text()}`);
}

/** Điền form ĐĂNG KÝ của Keycloak (theme keycloak.v2) — đúng các ô khách thật nhìn thấy. */
export async function fillKeycloakRegistration(
  page: Page, u: { username: string; email: string; password: string },
): Promise<void> {
  await page.locator('#username').fill(u.username);
  await page.locator('#email').fill(u.email);
  await page.locator('#firstName').fill('Khach');
  await page.locator('#lastName').fill('E2E');
  await page.locator('#password').fill(u.password);
  await page.locator('#password-confirm').fill(u.password);
  await page.locator('input[type=submit], button[type=submit]').first().click();
}

export function uniqueUser() {
  const id = `e2e${Date.now()}`;
  return { username: id, email: `${id}@example.com`, password: 'Passw0rd!e2e' };
}
