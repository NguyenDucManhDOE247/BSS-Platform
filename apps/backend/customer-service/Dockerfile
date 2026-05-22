# syntax=docker/dockerfile:1.6
#
# Multi-stage build:
#   • Stage 1 builds the fat JAR with Maven + JDK 21
#   • Stage 2 ships the JAR on a minimal JRE 21 runtime
#
# The final image is < 250 MB. For something even smaller, look into
# jlink or GraalVM native-image — both are reasonable next steps.

FROM eclipse-temurin:21-jdk-jammy AS build
WORKDIR /workspace

# Cache dependencies layer separately from source code.
COPY pom.xml .
COPY .mvn/ .mvn/
COPY mvnw .
RUN --mount=type=cache,target=/root/.m2 \
    ./mvnw dependency:go-offline -B

COPY src/ src/
RUN --mount=type=cache,target=/root/.m2 \
    ./mvnw -B clean package -DskipTests

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
