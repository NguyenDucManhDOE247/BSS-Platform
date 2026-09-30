# syntax=docker/dockerfile:1.7
# Keycloak cho dev/staging/prod — image "optimized" (ADR-011, dọn nợ Giai đoạn 9).
#
# Vì sao không dùng thẳng quay.io/keycloak/keycloak như trước:
#   `kc.sh start` (không --optimized) chạy bước "augmentation" của Quarkus MỖI LẦN khởi động — build
#   lại runtime theo các build option (db, health, metrics, relative path) rồi GHI vào
#   /opt/keycloak/lib/quarkus. Hệ quả: (1) phải tắt readOnlyRootFilesystem (ngoại lệ duy nhất với
#   CLAUDE.md §7), (2) khởi động chậm hơn hẳn (startupProbe phải chờ tới 5 phút).
#   Ở đây bước đó chạy MỘT LẦN lúc `docker build`; lúc chạy `start --optimized` chỉ đọc, không ghi
#   gì vào rootfs → bật lại readOnlyRootFilesystem: true (chỉ cần emptyDir cho /tmp và
#   /opt/keycloak/data).
#
# Build option (đóng băng vào image — đổi giá trị lúc chạy sẽ bị Keycloak từ chối/khởi động lại
# augmentation): KC_DB, KC_HEALTH_ENABLED, KC_METRICS_ENABLED, KC_HTTP_RELATIVE_PATH,
# KC_HTTP_MANAGEMENT_RELATIVE_PATH. Mọi thứ khác (DB host/user, hostname, cache, log) vẫn là biến
# môi trường lúc chạy — xem infrastructure/kubernetes/components/keycloak-aws/deployment.yaml.
#
# Local (kind + docker-compose) VẪN dùng image gốc với `start-dev` + H2 — không cần image này.
# Đổi version: sửa ARG dưới đây VÀ image ở overlays/local/keycloak + deploy/docker-compose.yml để
# realm/test chạy cùng một bản Keycloak ở mọi nơi.
ARG KEYCLOAK_VERSION=26.7.4

FROM quay.io/keycloak/keycloak:${KEYCLOAK_VERSION} AS builder
ENV KC_DB=postgres \
    KC_HEALTH_ENABLED=true \
    KC_METRICS_ENABLED=true \
    KC_HTTP_RELATIVE_PATH=/auth \
    KC_HTTP_MANAGEMENT_RELATIVE_PATH=/
RUN /opt/keycloak/bin/kc.sh build

FROM quay.io/keycloak/keycloak:${KEYCLOAK_VERSION}
COPY --from=builder /opt/keycloak/ /opt/keycloak/
# Image gốc đã chạy UID 1000 (không phải root) — giữ nguyên, khớp runAsUser trong manifest.
USER 1000
ENTRYPOINT ["/opt/keycloak/bin/kc.sh"]
CMD ["start", "--optimized"]
