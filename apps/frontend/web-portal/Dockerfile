# syntax=docker/dockerfile:1.6
# checkpoint GD6 #3: thay đổi vô hại để kiểm chứng CD chỉ đổi đúng service này
#
# Multi-stage:
#   • build:  Node 24 (Active LTS) builds the static bundle
#   • runtime: Nginx serves the bundle on port 8080, running as a non-root user

FROM node:24-alpine AS build
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --no-audit --no-fund
COPY . .
RUN npm run build

# B-05 fix: plain `nginx:1.27-alpine` + manually switching to a non-root user still failed on
# `docker run` (works "by accident" on K8s only because the Deployment manifest mounts an
# emptyDir over /var/run). The stock nginx.conf's `pid /run/nginx.pid;` directive points at a
# directory owned by root that a non-root master process can't write to — nginx never gets
# past that line, regardless of chown'ing /var/cache or /var/log.
# `nginxinc/nginx-unprivileged` is the same nginx image reconfigured specifically for this:
# pid file moved to /tmp, cache/log directories already owned by the non-root user, and it
# listens on 8080 by default — no manual `adduser`/`chown`/`USER` dance needed at all.
FROM nginxinc/nginx-unprivileged:1.30-alpine

# Giai đoạn 6: a NEW HIGH CVE (libexpat 2.8.4-r0, fixed in 2.8.5-r0) appeared in the Alpine base image on
# 2026-09-25 and Trivy (ci-frontend.yml) blocks every PR that touches this app. The upstream base tag
# had not been rebuilt yet, so patch just that package here. Root only for this one layer; the final
# user is set back to the unprivileged uid 101 that nginx-unprivileged runs as (CLAUDE.md §10: non-root).
USER root
RUN apk upgrade --no-cache libexpat
USER 101
COPY --from=build /app/dist /usr/share/nginx/html
COPY nginx.conf /etc/nginx/conf.d/default.conf
EXPOSE 8080
CMD ["nginx", "-g", "daemon off;"]
