# ---------------------------------------------------------------------------
# Stage 1: resolve org.apache.iceberg.rest.RESTCatalogServer's runtime
# classpath. This class is Apache Iceberg's own REST catalog reference
# server (backed by JdbcCatalog) -- the same class tabulario/iceberg-rest
# wraps -- but that image's last tag (1.6.0) predates format-version 3
# entirely and rejects V3 CREATE TABLE requests server-side. We resolve the
# identical class against the CURRENT Iceberg version instead. See pom.xml
# for the full rationale.
# ---------------------------------------------------------------------------
FROM maven:3.9-eclipse-temurin-17 AS deps

ARG ICEBERG_VERSION=1.11.0
ARG JACKSON_VERSION=2.21.3
ARG JACKSON_ANNOTATIONS_VERSION=2.21
ARG HADOOP_VERSION=3.4.3
ARG JETTY_VERSION=12.1.8
ARG SQLITE_JDBC_VERSION=3.53.0.0
ARG SLF4J_VERSION=2.0.17

WORKDIR /build
COPY pom.xml /build/pom.xml

RUN mvn -q -B -f /build/pom.xml \
      -Diceberg.version="${ICEBERG_VERSION}" \
      -Djackson.version="${JACKSON_VERSION}" \
      -Djackson.annotations.version="${JACKSON_ANNOTATIONS_VERSION}" \
      -Dhadoop.version="${HADOOP_VERSION}" \
      -Djetty.version="${JETTY_VERSION}" \
      -Dsqlite.version="${SQLITE_JDBC_VERSION}" \
      -Dslf4j.version="${SLF4J_VERSION}" \
      dependency:copy-dependencies -DoutputDirectory=/lib -DincludeScope=runtime

# ---------------------------------------------------------------------------
# Stage 2: runtime image -- just a JRE + the resolved classpath.
# ---------------------------------------------------------------------------
FROM eclipse-temurin:17-jre-jammy

COPY --from=deps /lib /opt/iceberg-rest/lib/

EXPOSE 8181
WORKDIR /opt/iceberg-rest

ENTRYPOINT ["java", "-cp", "/opt/iceberg-rest/lib/*", "org.apache.iceberg.rest.RESTCatalogServer"]
