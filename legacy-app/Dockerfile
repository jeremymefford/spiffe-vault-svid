FROM maven:3.9.9-eclipse-temurin-17 AS build
WORKDIR /src

COPY pom.xml ./
COPY src ./src

RUN mvn -q -DskipTests package

FROM eclipse-temurin:17-jre-jammy
WORKDIR /app

COPY --from=build /src/target/legacy-app-0.0.1-SNAPSHOT.jar /app/legacy-app.jar

ENTRYPOINT ["java", "-jar", "/app/legacy-app.jar"]
