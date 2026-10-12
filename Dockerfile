FROM maven:3.9.11-eclipse-temurin-21 AS build
WORKDIR /build
COPY pom.xml .
RUN mvn -B -ntp dependency:go-offline
COPY src ./src
RUN mvn -B -ntp verify

FROM eclipse-temurin:21-jre-jammy
RUN groupadd --gid 10001 saludu && useradd --uid 10001 --gid saludu --no-create-home saludu \
    && mkdir -p /app /var/lib/salud-u/documents \
    && chown -R saludu:saludu /app /var/lib/salud-u
WORKDIR /app
COPY --from=build --chown=saludu:saludu /build/target/salud-u-backend-0.0.1-SNAPSHOT.jar app.jar
USER 10001:10001
EXPOSE 8080
ENTRYPOINT ["java", "-jar", "/app/app.jar"]
