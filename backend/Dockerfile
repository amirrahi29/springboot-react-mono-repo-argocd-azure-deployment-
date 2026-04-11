# Build from repository root: docker build -f backend/Dockerfile .
# Gradle (node-gradle) runs npm in ../frontend and packs dist into the JAR.
FROM eclipse-temurin:17-jdk-jammy AS build
WORKDIR /workspace/backend
COPY backend/ ./
COPY frontend/ ../frontend/
RUN chmod +x gradlew && ./gradlew bootJar --no-daemon -x test

FROM eclipse-temurin:17-jre-alpine
WORKDIR /app
RUN addgroup -g 1000 -S spring && adduser -u 1000 -G spring -S spring
COPY --chown=spring:spring --from=build /workspace/backend/build/libs/*.jar app.jar
USER spring
ENV HOME=/tmp
ENV SERVER_PORT=8081
EXPOSE 8081
LABEL org.opencontainers.image.title="rahi-chat-app" \
  org.opencontainers.image.description="Spring Boot + React monorepo (GitOps)"
ENTRYPOINT ["java", "-XX:MaxRAMPercentage=75.0", "-Djava.io.tmpdir=/tmp", "-jar", "/app/app.jar"]
