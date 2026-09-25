# syntax=docker/dockerfile:1.6
# B-05 fix — see web-portal/Dockerfile for the full explanation of why
# nginxinc/nginx-unprivileged replaces plain nginx + manual chown/USER here.
FROM node:24-alpine AS build
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --no-audit --no-fund
COPY . .
RUN npm run build

FROM nginxinc/nginx-unprivileged:1.30-alpine

# Giai đoạn 6: a NEW HIGH CVE (libexpat 2.8.4-r0, fixed in 2.8.5-r0) appeared in the Alpine base image on
# 2026-09-25 and Trivy (ci-frontend.yml) blocks every PR that touches this app — same fix as web-portal.
# Root only for this one layer; the final user is set back to uid 101 (what nginx-unprivileged runs as).
USER root
RUN apk upgrade --no-cache libexpat
USER 101

# B-06 (tiếp): file build phải nằm dưới thư mục con "admin/" — xem giải thích đầy đủ trong
# nginx.conf. Vite base: '/admin/' làm HTML/JS tham chiếu đúng "/admin/assets/..." từ trình
# duyệt; đây là nửa còn lại — chỗ file thực sự nằm trên đĩa phải khớp với đường dẫn đó.
COPY --from=build /app/dist /usr/share/nginx/html/admin
COPY nginx.conf /etc/nginx/conf.d/default.conf
EXPOSE 8080
CMD ["nginx", "-g", "daemon off;"]
