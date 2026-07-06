# Multi-stage build for the review-service.
#
# MAVEN_PROFILE:
#   default -> plain Spring Boot app (no OpenTelemetry dependency)
#   starter -> OpenTelemetry Spring Boot Starter compiled in (Lab 2, part 2)
#
# The OpenTelemetry Java agent is always shipped in the image at
# /otel/opentelemetry-javaagent.jar but stays INACTIVE until the
# JAVA_TOOL_OPTIONS=-javaagent:... env var is set (Lab 2, part 1).

ARG MAVEN_PROFILE=default

FROM maven:3.9-eclipse-temurin-21 AS build
ARG MAVEN_PROFILE
WORKDIR /app
COPY pom.xml .
COPY src ./src
RUN mvn -q -P ${MAVEN_PROFILE} -DskipTests package

# Keep the agent version in sync with opentelemetry-instrumentation.version in pom.xml
FROM curlimages/curl:8.11.0 AS agent
ARG OTEL_AGENT_VERSION=2.14.0
RUN curl -sSfL -o /tmp/opentelemetry-javaagent.jar \
    https://github.com/open-telemetry/opentelemetry-java-instrumentation/releases/download/v${OTEL_AGENT_VERSION}/opentelemetry-javaagent.jar

FROM eclipse-temurin:21-jre
WORKDIR /app
COPY --from=agent /tmp/opentelemetry-javaagent.jar /otel/opentelemetry-javaagent.jar
COPY --from=build /app/target/review-service-*.jar /app/app.jar
EXPOSE 8080
ENTRYPOINT ["java", "-jar", "/app/app.jar"]
