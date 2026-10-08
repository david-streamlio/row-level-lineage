# Builds only the OpenLineage MetricsReporter jar, for Kafka Connect
# (compose.connect-lineage.yml); spark-demo builds the same source in its own
# first stage. Offline-friendly the same way: dependencies + plugins re-download
# only when pom.xml changes; a source change rebuilds with no network.
FROM maven:3.9-eclipse-temurin-17 AS build
ARG ICEBERG_VERSION=1.11.0
WORKDIR /build
COPY pom.xml ./pom.xml
RUN mvn -q -B -Diceberg.version=${ICEBERG_VERSION} dependency:go-offline package
COPY src ./src
RUN --network=none mvn -o -q -B -Diceberg.version=${ICEBERG_VERSION} package

FROM busybox:1.36
COPY --from=build /build/target/openlineage-metrics-reporter-1.0.0.jar /openlineage-metrics-reporter.jar
