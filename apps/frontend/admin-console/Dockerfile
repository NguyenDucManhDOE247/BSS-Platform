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
# B-06 (tiếp): file build phải nằm dưới thư mục con "admin/" — xem giải thích đầy đủ trong
# nginx.conf. Vite base: '/admin/' làm HTML/JS tham chiếu đúng "/admin/assets/..." từ trình
# duyệt; đây là nửa còn lại — chỗ file thực sự nằm trên đĩa phải khớp với đường dẫn đó.
COPY --from=build /app/dist /usr/share/nginx/html/admin
COPY nginx.conf /etc/nginx/conf.d/default.conf
EXPOSE 8080
CMD ["nginx", "-g", "daemon off;"]
