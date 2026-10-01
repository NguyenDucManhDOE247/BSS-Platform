# syntax=docker/dockerfile:1.6
# checkpoint GD6 #2: thay đổi vô hại để kiểm chứng CD chỉ đổi đúng service này
# B-01 fix — see product-catalog/Dockerfile for the full explanation.
FROM maven:3.9.16-eclipse-temurin-21 AS build
WORKDIR /workspace
COPY pom.xml .
RUN --mount=type=cache,target=/root/.m2 mvn -B dependency:go-offline
COPY src/ src/
RUN --mount=type=cache,target=/root/.m2 mvn -B clean package -DskipTests

FROM eclipse-temurin:21-jre-jammy
# CVE-2026-84782 (libssl3, HIGH — 2026-10-01): bản vá đã có trong apt của Ubuntu jammy nhưng tag
# eclipse-temurin:21-jre-jammy chưa được build lại → Trivy (ci-backend) chặn mọi PR backend. Nâng đúng 2 gói
# OpenSSL ở đây (stage này đang chạy root, trước USER bss); bỏ khi base upstream đã có >= 3.0.2-0ubuntu1.30.
RUN apt-get update && apt-get install -y --no-install-recommends --only-upgrade libssl3 openssl \
    && rm -rf /var/lib/apt/lists/*
RUN groupadd --system bss && useradd --system --gid bss bss
USER bss
WORKDIR /app
COPY --from=build /workspace/target/*.jar app.jar
EXPOSE 8080
ENTRYPOINT ["java", "-XX:MaxRAMPercentage=75.0", "-XX:+UseG1GC", "-XX:+ExitOnOutOfMemoryError", "-jar", "/app/app.jar"]
