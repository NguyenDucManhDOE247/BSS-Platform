import { expect, type Browser, type Page } from '@playwright/test';

/** Tài khoản mẫu trong realm kind (overlays/local/keycloak/bss-users-0.json) — chỉ tồn tại ở local. */
export const ADMIN = { username: 'admin1', password: 'admin1pass' };
export const CUSTOMER1 = { username: 'customer1', password: 'customer1pass' };

/** Điền form ĐĂNG NHẬP của Keycloak (theme keycloak.v2). */
export async function fillKeycloakLogin(page: Page, u: { username: string; password: string }): Promise<void> {
  await page.locator('#username').fill(u.username);
  await page.locator('#password').fill(u.password);
  await page.locator('input[type=submit], button[type=submit]').first().click();
}

/** Mở admin-console và đăng nhập bằng tài khoản admin (qua trang Keycloak thật, PKCE). */
export async function loginAdminConsole(page: Page, u = ADMIN): Promise<void> {
  await page.goto('/admin/');
  await page.getByRole('button', { name: 'Đăng nhập' }).click();
  await expect(page).toHaveURL(/\/auth\/realms\/bss\//);
  await fillKeycloakLogin(page, u);
  // PHẢI chờ app nhận code + đổi lấy token xong. Không chờ → `page.goto` ngay sau đó chạy đua với
  // redirect `/admin/?code=...` và hủy nó: trang mới không có phiên, không gọi API nào (lần chạy đầu
  // treo đúng như vậy ở bước 8 của hành trình khách — trace chỉ thấy /admin/?code=... bị bỏ dở).
  await expect(page.getByRole('navigation').getByRole('button', { name: 'Đăng xuất' })).toBeVisible();
}

/**
 * Nhân viên duyệt khách BẰNG GIAO DIỆN admin-console (GĐ9 việc 5 — thay cho gọi API trực tiếp như
 * trước). Chạy trong 1 browser context RIÊNG: nhân viên và khách là 2 người, 2 phiên đăng nhập.
 */
export async function approveCustomerInAdminConsole(browser: Browser, email: string, shotPath?: string): Promise<void> {
  const context = await browser.newContext();
  const page = await context.newPage();
  try {
    await loginAdminConsole(page);
    await page.getByRole('navigation').getByRole('link', { name: 'Khách hàng', exact: true }).click();
    await page.getByLabel('Trạng thái').selectOption('Initialized');
    await page.getByLabel('Tìm khách').fill(email);
    await page.getByRole('button', { name: 'Tìm', exact: true }).click();
    const row = page.getByTestId(`customer-${email}`);
    await expect(row.getByTestId('status')).toHaveText('Initialized');
    if (shotPath) await page.screenshot({ path: `${shotPath}-truoc.png`, fullPage: true });
    // Chờ PATCH duyệt trả 2xx RỒI mới đổi bộ lọc. Không chờ → lọc mới có thể tới server TRƯỚC khi PATCH
    // ghi xong (ingress log lần đỏ 2026-09-29, ngay sau rollout JVM còn lạnh: GET và PATCH cùng giây) →
    // bảng hiện trạng thái cũ `Initialized` và không tự tải lại (đỏ 1/3 lần chạy).
    await Promise.all([
      page.waitForResponse((r) => r.request().method() === 'PATCH' && r.url().includes('/customer/') && r.ok()),
      row.getByRole('button', { name: 'Duyệt', exact: true }).click(),
    ]);
    // Sau khi duyệt, khách rời bộ lọc "Initialized" → bỏ lọc để thấy trạng thái mới.
    await page.getByLabel('Trạng thái').selectOption('');
    await expect(row.getByTestId('status')).toHaveText('Active');
    if (shotPath) await page.screenshot({ path: `${shotPath}-sau.png`, fullPage: true });
  } finally {
    await context.close();
  }
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
