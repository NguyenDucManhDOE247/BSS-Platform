import { defineConfig, devices } from '@playwright/test';

/**
 * Giai đoạn 9 việc 6 — E2E trình duyệt thật cho web-portal + admin-console trên kind.
 * Chạy bằng `scripts/e2e-browser.sh` (Docker image Playwright ghim CÙNG version với package.json →
 * có sẵn Chromium + thư viện hệ thống, không cần sudo cài gì trên máy).
 *
 * Luồng chạy tuần tự (workers: 1): các bước phụ thuộc nhau (đăng ký → duyệt → mua) và cùng dùng 1
 * cluster thật — chạy song song chỉ tạo nhiễu, không nhanh hơn đáng kể.
 */
export default defineConfig({
  testDir: './tests',
  fullyParallel: false,
  workers: 1,
  timeout: 120_000,
  expect: { timeout: 20_000 },
  reporter: [['list'], ['html', { open: 'never', outputFolder: 'playwright-report' }]],
  use: {
    baseURL: process.env.BASE_URL ?? 'http://bss.localhost',
    screenshot: 'on',
    trace: 'retain-on-failure',
    locale: 'vi-VN',
  },
  projects: [{ name: 'chromium', use: { ...devices['Desktop Chrome'] } }],
});
