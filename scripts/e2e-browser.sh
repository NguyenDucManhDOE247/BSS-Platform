#!/usr/bin/env bash
# Giai đoạn 9 việc 6 — chạy test E2E trình duyệt thật (tests/e2e-browser, Playwright/Chromium) vào
# cluster kind đang chạy (http://bss.localhost).
#
# Chạy trong Docker image Playwright ghim CÙNG version với tests/e2e-browser/package.json: image có sẵn
# Chromium + thư viện hệ thống → không cần `sudo` cài gì trên máy.
#
# `--network host`: Chromium TỰ phân giải *.localhost về 127.0.0.1 (bỏ qua /etc/hosts và --add-host),
# nên container phải dùng chung mạng với máy chạy Docker — nơi kind publish cổng 80 của ingress
# (kind.yaml extraPortMappings). Không dùng được host khác *.localhost: đăng nhập PKCE cần "secure
# context" (ADR-008 quyết định 7).
# `--add-host bss.localhost:127.0.0.1`: CHỈ Chromium tự hiểu *.localhost — phần gọi API bằng Node.js
# của test (request context, dùng getaddrinfo) cần dòng này trong /etc/hosts, nếu không sẽ
# `ENOTFOUND bss.localhost` (đã gặp thật ở lần chạy đầu).
#
# Dùng: ./scripts/e2e-browser.sh            (kết quả + ảnh chụp: tests/e2e-browser/test-results/)
set -euo pipefail
cd "$(dirname "$0")/.."
PW_VERSION=$(sed -n 's/.*"@playwright\/test": *"\([0-9.]*\)".*/\1/p' tests/e2e-browser/package.json)
docker run --rm --network host --add-host bss.localhost:127.0.0.1 \
  -e BASE_URL="${BASE_URL:-http://bss.localhost}" \
  -v "$PWD/tests/e2e-browser:/work" -w /work \
  --user "$(id -u):$(id -g)" -e HOME=/tmp \
  "mcr.microsoft.com/playwright:v${PW_VERSION}-noble" \
  bash -c "npm ci --no-audit --no-fund --loglevel=error && npx playwright test"
