#!/usr/bin/env bash
# Test cho scripts/check-migrations.sh — dựng repo git giả có một service với migration V1, V2 trên nhánh
# `main`, rồi mỗi ca test tạo một nhánh riêng thêm/sửa file và chạy checker với BASE = main.
#
#   ./scripts/tests/check-migrations.test.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK="$HERE/../check-migrations.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=t@t

R="$WORK/repo"
DIR="apps/backend/customer-service/src/main/resources/db/migration"
git init -q "$R"
git -C "$R" config core.autocrlf false
git -C "$R" checkout -q -b main
mkdir -p "$R/$DIR"
cat > "$R/$DIR/V1__init.sql" <<'SQL'
CREATE TABLE customers (id UUID PRIMARY KEY, name VARCHAR(255) NOT NULL, email VARCHAR(255) NOT NULL);
SQL
echo "ALTER TABLE customers ALTER COLUMN name TYPE VARCHAR(300);" > "$R/$DIR/V2__widen_name.sql"
git -C "$R" add -A && git -C "$R" commit -q -m base

pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "  ✓ $1"; }
bad() { fail=$((fail + 1)); echo "  ✗ $1"; [ -z "${2:-}" ] || echo "      $2"; }

# case "mô tả" mong_đợi(pass|fail) 'lệnh chạy trong repo, trên nhánh mới, để tạo thay đổi'
case_() {
  local desc="$1" want="$2" setup="$3" out rc
  git -C "$R" checkout -q main && git -C "$R" checkout -q -b "t$RANDOM$RANDOM"
  ( cd "$R" && eval "$setup" ) >/dev/null 2>&1
  git -C "$R" add -A && git -C "$R" commit -q --allow-empty -m change
  out="$(cd "$R" && "$CHECK" main 2>&1)"; rc=$?
  if [ "$want" = pass ] && [ "$rc" -eq 0 ]; then ok "$desc"
  elif [ "$want" = fail ] && [ "$rc" -eq 1 ]; then ok "$desc"
  else bad "$desc" "mong đợi $want, exit=$rc — $(tr '\n' '|' <<<"$out" | cut -c1-260)"; fi
  git -C "$R" checkout -q main
}
new() { echo "$2" > "$R/$DIR/$1"; }   # (dùng trong eval: cd đã ở repo)

echo "── migration MỚI tương thích ngược → đạt"
case_ "thêm cột NULLABLE (bước expand)"                    pass "echo 'ALTER TABLE customers ADD COLUMN email_verified BOOLEAN;' > $DIR/V3__add_email_verified.sql"
case_ "thêm cột NOT NULL có DEFAULT"                       pass "echo 'ALTER TABLE customers ADD COLUMN tier VARCHAR(16) NOT NULL DEFAULT '\"'\"'basic'\"'\"';' > $DIR/V3__tier.sql"
case_ "tạo bảng mới (có NOT NULL) — không phá gì cả"       pass "echo 'CREATE TABLE audit (id UUID PRIMARY KEY, at TIMESTAMPTZ NOT NULL);' > $DIR/V3__audit.sql"
case_ "tạo index / thêm CHECK có 'not null' trong biểu thức" pass "printf 'CREATE INDEX ix_c ON customers(email);\nALTER TABLE customers ADD CONSTRAINT ck CHECK (email IS NOT NULL);\n' > $DIR/V3__idx.sql"
case_ "chú thích chứa 'drop column' KHÔNG bị bắt nhầm"      pass "printf -- '-- later we will DROP COLUMN legacy_x, not now\nALTER TABLE customers ADD COLUMN note TEXT;\n' > $DIR/V3__note.sql"
case_ "service mới với V1 đầu tiên"                        pass "mkdir -p apps/backend/new-service/src/main/resources/db/migration && echo 'CREATE TABLE t (id INT NOT NULL);' > apps/backend/new-service/src/main/resources/db/migration/V1__init.sql"
case_ "PR không đụng migration nào"                        pass "echo x > README.md"

echo
echo "── phá tương thích ngược → chặn"
case_ "ADD COLUMN NOT NULL không DEFAULT"                  fail "echo 'ALTER TABLE customers ADD COLUMN tier VARCHAR(16) NOT NULL;' > $DIR/V3__tier.sql"
case_ "ADD COLUMN NOT NULL không DEFAULT — nhiều dòng"     fail "printf 'ALTER TABLE customers\n  ADD COLUMN tier VARCHAR(16)\n  NOT NULL;\n' > $DIR/V3__tier.sql"
case_ "DROP COLUMN"                                        fail "echo 'ALTER TABLE customers DROP COLUMN phone;' > $DIR/V3__drop.sql"
case_ "DROP TABLE"                                         fail "echo 'DROP TABLE customers;' > $DIR/V3__drop.sql"
case_ "RENAME COLUMN"                                      fail "echo 'ALTER TABLE customers RENAME COLUMN name TO full_name;' > $DIR/V3__rename.sql"
case_ "RENAME bảng"                                        fail "echo 'ALTER TABLE customers RENAME TO clients;' > $DIR/V3__rename.sql"
case_ "ALTER COLUMN TYPE"                                  fail "echo 'ALTER TABLE customers ALTER COLUMN name TYPE TEXT;' > $DIR/V3__type.sql"
case_ "SET NOT NULL"                                       fail "echo 'ALTER TABLE customers ALTER COLUMN phone SET NOT NULL;' > $DIR/V3__nn.sql"
case_ "TRUNCATE"                                           fail "echo 'TRUNCATE customers;' > $DIR/V3__wipe.sql"

echo
echo "── bước CONTRACT có chú thích xác nhận → đạt (kèm cảnh báo)"
case_ "DROP COLUMN + '-- expand-contract:'"                pass "printf -- '-- expand-contract: v1.4.0 đã ngừng đọc cột phone ở mọi môi trường (2026-10-01)\nALTER TABLE customers DROP COLUMN phone;\n' > $DIR/V3__drop_phone.sql"
case_ "SET NOT NULL + '-- expand-contract:'"               pass "printf -- '-- expand-contract: email_verified đã backfill, v1.3.0 luôn ghi giá trị\nALTER TABLE customers ALTER COLUMN name SET NOT NULL;\n' > $DIR/V3__nn.sql"
case_ "chú thích KHÔNG cứu được ADD COLUMN NOT NULL (lỗi cứng)" fail "printf -- '-- expand-contract: xin cho qua\nALTER TABLE customers ADD COLUMN tier VARCHAR(16) NOT NULL;\n' > $DIR/V3__tier.sql"

echo
echo "── quy tắc Flyway → chặn"
case_ "sửa migration đã có (checksum mismatch)"            fail "echo '-- edited' >> $DIR/V1__init.sql"
case_ "xóa migration đã có"                                fail "git rm -q $DIR/V2__widen_name.sql"
case_ "đổi tên migration đã có"                            fail "git mv $DIR/V2__widen_name.sql $DIR/V2__widen_name_again.sql"
case_ "version mới trùng version đã có (V2)"               fail "echo 'CREATE TABLE a (id INT);' > $DIR/V2__other.sql"
case_ "version mới nhỏ hơn version cao nhất"               fail "echo 'CREATE TABLE a (id INT);' > $DIR/V1__other.sql"
case_ "tên file sai dạng"                                  fail "echo 'CREATE TABLE a (id INT);' > $DIR/V3-add-thing.sql"

echo
echo "── tham số"
if ( cd "$R" && "$CHECK" khong-co-nhanh-nay >/dev/null 2>&1 ); then bad "BASE không tồn tại phải báo lỗi"; else ok "BASE không tồn tại → báo lỗi (không im lặng cho qua)"; fi

echo
echo "════════ kết quả: $pass đạt, $fail hỏng ════════"
[ "$fail" -eq 0 ]
