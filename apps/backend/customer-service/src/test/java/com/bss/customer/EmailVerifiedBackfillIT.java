package com.bss.customer;

import org.flywaydb.core.Flyway;
import org.junit.jupiter.api.Test;
import org.testcontainers.containers.PostgreSQLContainer;
import org.testcontainers.junit.jupiter.Container;
import org.testcontainers.junit.jupiter.Testcontainers;

import java.sql.DriverManager;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * Schema migration Release B (dọn nợ GĐ6): V4 phải lấp đúng các dòng email_verified = NULL mà code
 * Release A (chưa biết cột) để lại — kiểm trên Postgres thật bằng chính Flyway, dừng ở V3 (trạng thái
 * DB lúc Release A đang chạy), chèn dữ liệu kiểu "code cũ", rồi migrate tiếp.
 */
@Testcontainers
class EmailVerifiedBackfillIT {

    @Container
    static PostgreSQLContainer<?> postgres = new PostgreSQLContainer<>("postgres:15-alpine");

    @Test
    void v4_backfills_rows_left_null_by_release_a_and_keeps_explicit_values() throws Exception {
        Flyway toV3 = Flyway.configure()
                .dataSource(postgres.getJdbcUrl(), postgres.getUsername(), postgres.getPassword())
                .target("3").load();
        toV3.migrate();

        try (var c = DriverManager.getConnection(postgres.getJdbcUrl(), postgres.getUsername(), postgres.getPassword());
             var st = c.createStatement()) {
            // Code Release A: không biết cột → INSERT không nhắc tới email_verified → NULL.
            st.executeUpdate("INSERT INTO customers (id, name, email, status, created_at, updated_at) VALUES "
                    + "(gen_random_uuid(), 'Cu', 'cu@x.vn', 'Active', now(), now())");
            // Dòng đã có giá trị thật (vd. Release B chạy song song) — backfill KHÔNG được ghi đè.
            st.executeUpdate("INSERT INTO customers (id, name, email, status, email_verified, created_at, updated_at) VALUES "
                    + "(gen_random_uuid(), 'Moi', 'moi@x.vn', 'Active', true, now(), now())");
        }

        Flyway.configure()
                .dataSource(postgres.getJdbcUrl(), postgres.getUsername(), postgres.getPassword())
                .load().migrate();

        try (var c = DriverManager.getConnection(postgres.getJdbcUrl(), postgres.getUsername(), postgres.getPassword());
             var st = c.createStatement()) {
            var rs = st.executeQuery("SELECT email, email_verified FROM customers ORDER BY email");
            rs.next();
            assertThat(rs.getString(1)).isEqualTo("cu@x.vn");
            assertThat(rs.getObject(2)).isEqualTo(false);  // NULL → false
            rs.next();
            assertThat(rs.getString(1)).isEqualTo("moi@x.vn");
            assertThat(rs.getObject(2)).isEqualTo(true);   // giữ nguyên
            var nulls = st.executeQuery("SELECT count(*) FROM customers WHERE email_verified IS NULL");
            nulls.next();
            assertThat(nulls.getInt(1)).isZero();
        }
    }
}
