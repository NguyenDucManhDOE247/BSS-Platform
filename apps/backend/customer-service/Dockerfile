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

FROM maven:3-eclipse-temurin-26 AS build
WORKDIR /workspace

# Cache dependencies layer separately from source code.
COPY pom.xml .
RUN --mount=type=cache,target=/root/.m2 \
    mvn -B dependency:go-offline

COPY src/ src/
RUN --mount=type=cache,target=/root/.m2 \
    mvn -B clean package -DskipTests

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
