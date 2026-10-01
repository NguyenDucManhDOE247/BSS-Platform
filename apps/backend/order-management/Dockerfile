# syntax=docker/dockerfile:1.6
# B-01 fix — see product-catalog/Dockerfile for the full explanation (Maven wasn't on the
# base image; `|| true` was hiding that instead of failing the build where it actually broke).
FROM maven:3.9.16-eclipse-temurin-21 AS build
WORKDIR /workspace
# B-15: com.bss:bss-common-java đến từ GitHub Packages (cần auth) — token vào qua BuildKit secret,
# không nằm trong layer nào. Giải thích đầy đủ: customer-service/Dockerfile.
COPY pom.xml .
RUN --mount=type=cache,target=/root/.m2 \
    --mount=type=secret,id=github_token,required=true \
    printf '<settings><servers><server><id>github</id><username>x-access-token</username><password>%s</password></server></servers></settings>' "$(cat /run/secrets/github_token)" > /tmp/settings.xml && \
    mvn -B -s /tmp/settings.xml dependency:go-offline
COPY src/ src/
RUN --mount=type=cache,target=/root/.m2 \
    --mount=type=secret,id=github_token,required=true \
    printf '<settings><servers><server><id>github</id><username>x-access-token</username><password>%s</password></server></servers></settings>' "$(cat /run/secrets/github_token)" > /tmp/settings.xml && \
    mvn -B -s /tmp/settings.xml clean package -DskipTests

FROM eclipse-temurin:21-jre-jammy
RUN groupadd --system bss && useradd --system --gid bss bss
USER bss
WORKDIR /app
COPY --from=build /workspace/target/*.jar app.jar
EXPOSE 8080
ENTRYPOINT ["java", "-XX:MaxRAMPercentage=75.0", "-XX:+UseG1GC", "-XX:+ExitOnOutOfMemoryError", "-jar", "/app/app.jar"]
