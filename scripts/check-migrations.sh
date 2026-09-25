#!/usr/bin/env bash
# Kiểm các Flyway migration MỚI trong PR có tương thích ngược không (Giai đoạn 6, course 11.6).
#
#   ./scripts/check-migrations.sh [BASE_REF]      # mặc định origin/main; cần lịch sử đủ để diff BASE...HEAD
#
# Vì sao cần: một rolling update (maxSurge 1 / maxUnavailable 0) luôn có một quãng vài phút mà Pod
# BẢN CŨ và Pod BẢN MỚI cùng chạy trên CÙNG một database — Pod mới chạy Flyway ngay lúc khởi động,
# nên Pod cũ thấy schema MỚI. Rollback ứng dụng (kể cả rollback tự động của CD, ADR-005) cũng đưa
# code cũ về chạy trên schema mới. Nghĩa là mỗi migration phải chạy được với CẢ code trước nó lẫn code
# sau nó. Cách làm chuẩn là expand → migrate → contract (docs/runbooks/schema-migration.md).
#
# Script này chỉ xét các file migration được THÊM/SỬA/XÓA/ĐỔI TÊN so với BASE_REF:
#
#   LỖI (exit 1, không có cách né):
#     • sửa / xóa / đổi tên một migration đã có — Flyway lưu checksum của file đã áp dụng; sửa 1 byte
#       là mọi Pod báo "Migration checksum mismatch" và không khởi động nổi
#     • version mới không lớn hơn version cao nhất đã có trong cùng thư mục (hai PR cùng thêm V3 →
#       Flyway từ chối hoặc chạy sai thứ tự)
#     • ADD COLUMN ... NOT NULL mà không có DEFAULT — code cũ INSERT không biết cột này và lỗi ngay
#
#   PHÁ TƯƠNG THÍCH NGƯỢC (exit 1 — trừ khi file có dòng chú thích `-- expand-contract: <lý do>`
#   xác nhận đây là bước CONTRACT và code cũ đã hết chạy ở mọi môi trường):
#     • DROP TABLE / DROP COLUMN / TRUNCATE          • RENAME (cột, bảng)
#     • ALTER COLUMN ... TYPE                         • ALTER COLUMN ... SET NOT NULL
#
# Không phải một bộ phân tích SQL đầy đủ: nó bắt các lệnh nguy hiểm phổ biến bằng mẫu chữ. Nó là lưới
# an toàn cho người review, không thay thế việc suy nghĩ về "code cũ + schema mới".
set -euo pipefail

BASE="${1:-origin/main}"
# Pathspec kiểu git (`:(glob)`), truyền trong dấu nháy để SHELL không tự bung ký tự đại diện theo thư mục hiện tại.
GLOB=':(glob)apps/backend/*/src/main/resources/db/migration/*.sql'

git rev-parse --verify --quiet "$BASE^{commit}" >/dev/null \
  || { echo "check-migrations: không tìm thấy $BASE (checkout thiếu fetch-depth: 0?)" >&2; exit 2; }

# Mẫu chữ (đã hạ chữ thường, đã gộp khoảng trắng) cho từng loại lệnh nguy hiểm.
re_add_col='(^| )add (column )?(if not exists )?[a-z_][a-z0-9_]* [a-z]'
re_add_other='(^| )add (constraint|primary|foreign|unique|check|exclude)'
re_not_null='not null'
re_default='default'
re_drop='drop (table|column)'
re_rename='(rename (column|to))|(alter table [^ ]+ rename)'
re_type='alter column .* type'
re_set_nn='alter column .* set not null'
re_truncate='^ *truncate'

errors=0
warnings=0
err()  { echo "✗ $1"; errors=$((errors + 1)); }
warn() { echo "⚠ $1"; warnings=$((warnings + 1)); }

# --- 1. file đã có mà bị sửa/xóa/đổi tên --------------------------------------------------------
while IFS=$'\t' read -r status path rest; do
  [ -n "$status" ] || continue
  case "$status" in
    A) ;;  # xử lý ở bước 2
    M) err "$path — SỬA một migration đã có. Flyway giữ checksum của file đã áp dụng → mọi Pod báo checksum mismatch. Thêm migration MỚI (V<n+1>) để sửa." ;;
    D) err "$path — XÓA một migration đã có. Flyway coi là migration bị mất (validate fail)." ;;
    R*) err "$path → ${rest:-?} — ĐỔI TÊN một migration đã có (đổi version/mô tả = migration khác với Flyway)." ;;
  esac
done < <(git diff --name-status -M "$BASE...HEAD" -- "$GLOB")

# --- 2. file MỚI: version tăng dần + nội dung tương thích ngược ------------------------------------
version_of() { basename "$1" | sed -E 's/^V([0-9]+)__.*/\1/'; }

while IFS= read -r path; do
  [ -n "$path" ] || continue
  dir="$(dirname "$path")"
  file="$(basename "$path")"

  if ! [[ "$file" =~ ^V[0-9]+__[A-Za-z0-9_]+\.sql$ ]]; then
    err "$path — tên không đúng dạng V<số>__<mô_tả>.sql (Flyway sẽ bỏ qua hoặc báo lỗi)."
    continue
  fi

  # version cao nhất đã có ở BASE trong cùng thư mục
  max_base=0
  while IFS= read -r existing; do
    [ -n "$existing" ] || continue
    v="$(version_of "$existing")"
    [ "$v" -gt "$max_base" ] && max_base="$v"
  done < <(git ls-tree --name-only "$BASE" "$dir/" 2>/dev/null | grep -E '/V[0-9]+__' || true)
  this="$(version_of "$path")"
  if [ "$this" -le "$max_base" ]; then
    err "$path — version V$this không lớn hơn V$max_base đã có ở $BASE. Đổi số (rebase rồi đánh V$((max_base + 1)))."
  fi

  # Bỏ chú thích `--` (trừ để tìm annotation), gộp về một dòng, tách theo ';', hạ chữ thường.
  annotated=0
  grep -qiE '^[[:space:]]*--[[:space:]]*expand-contract:' "$path" && annotated=1
  stmts="$(sed -E 's/--.*$//' "$path" | tr '\r\n' '  ' | awk 'BEGIN{RS=";"} {gsub(/[[:space:]]+/," "); print tolower($0)}')"

  while IFS= read -r st; do
    [ -n "${st// /}" ] || continue
    reason=""
    hard=0
    if   [[ "$st" =~ $re_add_col ]] && ! [[ "$st" =~ $re_add_other ]] && [[ "$st" =~ $re_not_null ]] && ! [[ "$st" =~ $re_default ]]; then
      reason="ADD COLUMN ... NOT NULL không có DEFAULT — code cũ INSERT không có cột này sẽ lỗi ngay (bước 1: thêm cột NULLABLE, backfill, chỉ SET NOT NULL ở release sau)"; hard=1
    elif [[ "$st" =~ $re_drop ]]; then reason="DROP TABLE/COLUMN — code cũ còn query đối tượng này"
    elif [[ "$st" =~ $re_rename ]]; then reason="RENAME — code cũ tìm tên cũ"
    elif [[ "$st" =~ $re_type ]]; then reason="ALTER COLUMN ... TYPE — có thể viết lại cả bảng (khóa ACCESS EXCLUSIVE) và làm code cũ đọc/ghi sai kiểu"
    elif [[ "$st" =~ $re_set_nn ]]; then reason="SET NOT NULL — code cũ vẫn có thể ghi NULL"
    elif [[ "$st" =~ $re_truncate ]]; then reason="TRUNCATE — xóa dữ liệu mà code cũ còn cần"
    fi
    [ -n "$reason" ] || continue

    snippet="$(echo "$st" | cut -c1-90)"
    if [ "$hard" -eq 1 ]; then
      err "$path — $reason:  «$snippet»"
    elif [ "$annotated" -eq 1 ]; then
      warn "$path — $reason (đã xác nhận bằng '-- expand-contract:'):  «$snippet»"
    else
      err "$path — $reason:  «$snippet»
     Nếu đây thật sự là bước CONTRACT (mọi môi trường đã chạy code không còn dùng đối tượng này), thêm vào file một dòng
       -- expand-contract: <lý do + release nào đã ngừng dùng>
     Xem docs/runbooks/schema-migration.md."
    fi
  done <<<"$stmts"
done < <(git diff --name-only --diff-filter=A "$BASE...HEAD" -- "$GLOB")

echo ""
if [ "$errors" -gt 0 ]; then
  echo "check-migrations: $errors lỗi, $warnings cảnh báo."
  exit 1
fi
echo "check-migrations: OK ($warnings cảnh báo)."
