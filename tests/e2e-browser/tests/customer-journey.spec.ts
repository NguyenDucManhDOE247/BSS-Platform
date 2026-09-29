import { expect, test, type Page } from '@playwright/test';
import { approveCustomerByEmail, fillKeycloakRegistration, uniqueUser } from './helpers';

/**
 * Thanh điều hướng. Mặc định Playwright so khớp tên KHÔNG chính xác (chuỗi con, không phân biệt hoa
 * thường) → "Hóa đơn" khớp cả link "Xem hóa đơn" ở thân trang chủ (lần chạy đầu đỏ oan vì đúng lỗi
 * này). Kiểm menu thì phải khoanh vào đúng thanh nav + exact.
 */
const nav = (page: Page) => page.getByRole('navigation');

/**
 * Giai đoạn 9 — hành trình của 1 khách THẬT trên web-portal, bằng trình duyệt thật:
 * đăng ký (trang Keycloak) → tạo hồ sơ → bị chặn mua khi chưa duyệt → được duyệt → mua gói →
 * thấy đơn + hóa đơn của CHÍNH mình → đăng xuất.
 * Mỗi bước chụp ảnh (thư mục test-results/) làm bằng chứng cho checkpoint GĐ9.
 */
test('khách mới: đăng ký → hồ sơ → chờ duyệt → được duyệt → mua gói → đơn + hóa đơn', async ({ page, request, baseURL }) => {
  const user = uniqueUser();
  const shot = (name: string) => page.screenshot({ path: `test-results/journey/${name}.png`, fullPage: true });
  // In mọi lỗi/cảnh báo của TRÌNH DUYỆT ra log test — lỗi của oidc-client-ts (vd. không tải được
  // discovery) chỉ hiện ở console trình duyệt, không làm test tự nói ra nguyên nhân.
  page.on('console', (m) => { if (m.type() === 'error' || m.type() === 'warning') console.log(`[browser ${m.type()}]`, m.text()); });
  page.on('pageerror', (e) => console.log('[browser pageerror]', e.message));
  page.on('requestfailed', (r) => console.log('[browser requestfailed]', r.url(), r.failure()?.errorText));

  // 1. Trang chủ khi chưa đăng nhập: có nút Đăng ký, KHÔNG có menu Hóa đơn (hết "khách ma" dùng chung).
  await page.goto('/');
  await expect(nav(page).getByRole('button', { name: 'Đăng ký', exact: true })).toBeVisible();
  await expect(nav(page).getByRole('link', { name: 'Hóa đơn', exact: true })).toHaveCount(0);
  await shot('01-trang-chu-chua-dang-nhap');

  // 2. Đăng ký → chuyển sang trang Keycloak (PKCE) → quay về đã đăng nhập.
  await nav(page).getByRole('button', { name: 'Đăng ký', exact: true }).click();
  await expect(page).toHaveURL(/\/auth\/realms\/bss\//);
  await shot('02-trang-dang-ky-keycloak');
  await fillKeycloakRegistration(page, user);
  await expect(page.getByText('Xin chào')).toBeVisible();
  await expect(page).not.toHaveURL(/code=/); // code dùng 1 lần đã bị xóa khỏi thanh địa chỉ
  await shot('03-da-dang-nhap');

  // 3. Hồ sơ lần đầu → tạo → trạng thái chờ duyệt.
  await nav(page).getByRole('link', { name: 'Hồ sơ', exact: true }).click();
  await expect(page.getByRole('heading', { name: 'Hoàn tất hồ sơ khách hàng' })).toBeVisible();
  await page.getByLabel('Họ tên').fill('Nguyen Van E2E');
  await page.getByLabel('Số điện thoại').fill('0901234567');
  await page.getByRole('button', { name: 'Tạo hồ sơ' }).click();
  await expect(page.getByTestId('status')).toHaveText('Initialized');
  await expect(page.getByText(user.email)).toBeVisible(); // email lấy từ tài khoản đăng nhập
  await shot('04-ho-so-cho-duyet');

  // 4. Chưa được duyệt → trang mua gói giải thích lý do, không có nút mua.
  await nav(page).getByRole('link', { name: 'Gói cước', exact: true }).click();
  await page.getByRole('link', { name: /Đăng ký →/ }).first().click();
  await expect(page.getByTestId('not-active')).toContainText('chờ nhân viên duyệt');
  await expect(page.getByRole('button', { name: 'Xác nhận đăng ký' })).toHaveCount(0);
  const orderUrl = page.url();
  await shot('05-chua-duyet-khong-mua-duoc');

  // 5. Nhân viên duyệt (API thật; GĐ9 việc 5 sẽ đổi sang bấm trên admin-console).
  await approveCustomerByEmail(request, baseURL!, user.email);

  // 6. Tải lại → mua được → chuyển sang "Đơn hàng của tôi".
  await page.goto(orderUrl);
  await page.getByRole('button', { name: 'Xác nhận đăng ký' }).click();
  await expect(page).toHaveURL(/\/orders$/);
  await expect(page.getByRole('heading', { name: 'Đơn hàng của tôi' })).toBeVisible();
  await expect(page.locator('tbody tr')).toHaveCount(1); // chỉ đơn của CHÍNH khách này
  await shot('06-don-hang-cua-toi');

  // 7. Hóa đơn xuất hiện vài giây sau (outbox → EventBridge → SQS → billing), trang tự poll 5s.
  await nav(page).getByRole('link', { name: 'Hóa đơn', exact: true }).click();
  await expect(page.locator('tbody tr')).toHaveCount(1, { timeout: 60_000 });
  await expect(page.locator('tbody tr code')).toContainText('BSS-');
  await shot('07-hoa-don-cua-toi');

  // 8. Đăng xuất → quay về trang chủ, không còn menu riêng tư.
  await nav(page).getByRole('button', { name: 'Đăng xuất', exact: true }).click();
  await expect(nav(page).getByRole('button', { name: 'Đăng nhập', exact: true })).toBeVisible();
  await expect(nav(page).getByRole('link', { name: 'Hóa đơn', exact: true })).toHaveCount(0);
  await shot('08-da-dang-xuat');
});
