import { expect, test } from '@playwright/test';
import { CUSTOMER1, fillKeycloakLogin, loginAdminConsole } from './helpers';

/**
 * Giai đoạn 9 việc 5 — admin-console bằng trình duyệt thật trên kind.
 * Ảnh chụp từng bước: test-results/admin/ (bằng chứng checkpoint GĐ9).
 */

test('khách hàng (không có role admin) đăng nhập admin-console → bị chặn, không thấy trang quản trị', async ({ page }) => {
  await page.goto('/admin/');
  await page.getByRole('button', { name: 'Đăng nhập' }).click();
  await fillKeycloakLogin(page, CUSTOMER1);
  await expect(page.getByTestId('not-admin')).toContainText('customer1');
  await expect(page.getByRole('navigation')).toHaveCount(0); // không có menu quản trị nào
  await page.screenshot({ path: 'test-results/admin/01-khach-bi-chan.png', fullPage: true });
});

test('admin: dashboard có số thật + doanh thu; tạo gói → sửa giá → ngừng bán, web-portal phản ánh đúng', async ({ page, browser }) => {
  const shot = (name: string) => page.screenshot({ path: `test-results/admin/${name}.png`, fullPage: true });
  page.on('pageerror', (e) => console.log('[browser pageerror]', e.message));

  // 1. Đăng nhập → Dashboard: mọi ô có số (không kẹt "…" / lỗi "—"), doanh thu định dạng VND.
  await loginAdminConsole(page);
  await expect(page.getByRole('heading', { name: 'Admin Dashboard' })).toBeVisible();
  for (const tile of ['Khách hàng', 'Chờ duyệt', 'Gói cước', 'Đơn hàng', 'Hóa đơn']) {
    await expect(page.getByTestId(`tile-${tile}`)).toContainText(/\d/);
  }
  await expect(page.getByTestId('tile-Doanh thu (gồm VAT)')).toContainText('₫');
  await shot('02-dashboard');

  // 2. Tạo gói mới (tên duy nhất mỗi lần chạy).
  const name = `E2E Gói ${Date.now()}`;
  await page.getByRole('navigation').getByRole('link', { name: 'Gói cước', exact: true }).click();
  await page.getByLabel('Tên gói').fill(name);
  await page.getByLabel('Mô tả gói').fill('Gói tạo bởi test E2E');
  await page.getByLabel('Giá (VND)').fill('123000');
  // Chờ POST tạo gói trả 201 RỒI mới mở web-portal: không chờ thì trang của khách có thể tải danh sách
  // TRƯỚC khi gói được ghi (ingress log 2026-09-29: GET khách 08:57:41 đứng trước POST 201 cùng giây) →
  // trang không tự tải lại → đỏ oan. Hai bước sau (sửa giá, ngừng bán) đã chờ admin thấy kết quả.
  await Promise.all([
    page.waitForResponse((r) => r.request().method() === 'POST' && r.url().includes('/productOffering') && r.status() === 201),
    page.getByRole('button', { name: 'Tạo gói' }).click(),
  ]);
  // Gói mới có thể không nằm ở trang 1 → kiểm phía web-portal, nơi khách thật nhìn thấy.
  const portal = await browser.newContext();
  const guest = await portal.newPage();
  const card = guest.locator('article.plan-card', { has: guest.getByRole('heading', { name }) });
  await guest.goto('/plans');
  await expect(card).toContainText(/123\.000/);
  await guest.screenshot({ path: 'test-results/admin/03-web-portal-thay-goi-moi.png', fullPage: true });

  // 3. Tìm dòng của gói trong admin (lật trang tới khi thấy), sửa giá.
  const row = page.getByTestId(`offering-${name}`);
  while (!(await row.isVisible())) {
    const next = page.getByRole('button', { name: /Sau/ });
    if (await next.isDisabled()) throw new Error(`Không thấy gói ${name} trong danh sách admin`);
    await next.click();
  }
  await row.getByRole('button', { name: 'Sửa' }).click();
  await row.getByLabel('Giá mới').fill('99000');
  await row.getByRole('button', { name: 'Lưu' }).click();
  await expect(row).toContainText(/99\.000/);
  await shot('04-admin-sua-gia');
  await guest.goto('/plans');
  await expect(card).toContainText(/99\.000/);

  // 4. Ngừng bán → admin vẫn thấy (Retired), khách không còn thấy gói trên web-portal.
  await row.getByRole('button', { name: 'Ngừng bán' }).click();
  await expect(row.getByTestId('lifecycle')).toHaveText('Retired');
  await shot('05-admin-ngung-ban');
  await guest.goto('/plans');
  await expect(guest.getByRole('heading', { name: 'Các gói cước' })).toBeVisible();
  await expect(card).toHaveCount(0);
  await guest.screenshot({ path: 'test-results/admin/06-web-portal-het-goi.png', fullPage: true });
  await portal.close();
});
