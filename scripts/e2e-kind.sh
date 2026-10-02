#!/usr/bin/env bash
# Lối tắt giữ tên cũ (docs, Makefile, lab nhắc tới nó): kịch bản E2E nay dùng chung mọi môi trường ở
# scripts/e2e-flow.sh — file này chỉ chạy nó với `kind`.
set -euo pipefail
exec "$(dirname "$0")/e2e-flow.sh" kind "$@"
