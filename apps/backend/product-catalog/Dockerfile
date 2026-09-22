# syntax=docker/dockerfile:1.6
#
# B-01 fix: `eclipse-temurin:21-jdk-jammy` only has the JDK, not Maven — the old
# `RUN mvn dependency:go-offline ... || true` line failed with "mvn: not found" every time,
# and the trailing `|| true` swallowed that failure instead of surfacing it, so the *next*
# RUN (which has no `|| true`) was the one that finally errored out, several lines away from
# the real cause. `maven:...-eclipse-temurin-21` already has Maven installed — no wrapper,
# no `|| true` needed, and a genuine build failure now fails `docker build` where it happens.
FROM maven:3-eclipse-temurin-26 AS build
WORKDIR /workspace
COPY pom.xml .
RUN --mount=type=cache,target=/root/.m2 mvn -B dependency:go-offline
COPY src/ src/
RUN --mount=type=cache,target=/root/.m2 mvn -B clean package -DskipTests

FROM eclipse-temurin:21-jre-jammy
RUN groupadd --system bss && useradd --system --gid bss bss
USER bss
WORKDIR /app
COPY --from=build /workspace/target/*.jar app.jar
EXPOSE 8080
ENTRYPOINT ["java", "-XX:MaxRAMPercentage=75.0", "-XX:+UseG1GC", "-XX:+ExitOnOutOfMemoryError", "-jar", "/app/app.jar"]
