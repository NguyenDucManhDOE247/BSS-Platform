# syntax=docker/dockerfile:1.6
#
# Multi-stage build:
#   • Stage 1 builds the fat JAR with a Maven image that already has Maven on it.
#   • Stage 2 ships the JAR on a minimal JRE 21 runtime.
#
# B-01 fix: this used to COPY a Maven Wrapper (`.mvn/`, `mvnw`) that the repo never actually
# committed — `COPY mvnw .` failed outright ("not found"). Using a `maven:...-eclipse-temurin-21`
# image sidesteps the whole wrapper question: Maven is already on the image, so the build just
# calls `mvn` directly, and a real failure now actually fails `docker build` (the previous
# `|| true` on the dependency step — see the other 4 Dockerfiles before this fix — hid errors
# instead of surfacing them).
#
# The final image is ~500 MB (eclipse-temurin:21-jre-jammy base + Spring Boot fat jar +
# dependencies — measured after this fix, not guessed). For something meaningfully smaller,
# look into jlink (custom minimal JRE) or GraalVM native-image — both are reasonable next steps
# once the app itself is stable; premature at Giai đoạn 1.

FROM maven:3.9.16-eclipse-temurin-21 AS build
WORKDIR /workspace

# customer-service depends on com.bss:bss-common-java (Giai đoạn 3, PR #60), published to
# GitHub Packages. GitHub Packages requires auth for EVERY request, even reads on a public
# repo — and this Docker build is its own isolated environment: the `~/.m2/settings.xml` that
# `actions/setup-java`'s `server-id: github` writes on the CI *runner* (see ci-backend.yml) is
# invisible in here. A BuildKit secret carries the token in without ever writing it into an
# image layer or the build cache (unlike an ARG/ENV, which would land in `docker history`).
# `docker build --secret id=github_token,env=GITHUB_TOKEN ...` supplies it (see ci-backend.yml);
# building this image locally needs the same flag with a PAT that has `read:packages`.

# Cache dependencies layer separately from source code.
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

# ---------- runtime ---------- #

FROM eclipse-temurin:21-jre-jammy

# Run as non-root.
RUN groupadd --system bss && useradd --system --gid bss bss
USER bss

WORKDIR /app
COPY --from=build /workspace/target/*.jar app.jar

EXPOSE 8080

# JVM flags tuned for containerized environments. -XX:MaxRAMPercentage tells
# the JVM to respect cgroup memory limits set by Kubernetes.
ENTRYPOINT ["java", \
  "-XX:MaxRAMPercentage=75.0", \
  "-XX:+UseG1GC", \
  "-XX:+ExitOnOutOfMemoryError", \
  "-jar", "/app/app.jar"]
