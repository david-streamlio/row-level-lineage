# Spark container for the staged demo (Stages 02-05): same base pattern as
# preflight/docker/spark, plus a custom Iceberg MetricsReporter that emits
# Composable Lineage events on every commit. The stages read _row_id via
# duckdb-demo, but this image can too: Spark 4.0 + Iceberg 1.11 returns
# _row_id / _last_updated_sequence_number (checked 2026-10-06, same values as
# DuckDB). Only Flink's Iceberg source can't project them.

# ---------------------------------------------------------------------
# Stage 1: compile the tiny MetricsReporter jar.
# ---------------------------------------------------------------------
FROM maven:3.9-eclipse-temurin-17 AS reporter-build

ARG ICEBERG_VERSION=1.11.0

# Offline-friendly: the first RUN (dependencies + Maven plugins, by building
# an empty project) only re-runs when pom.xml changes; a source change only
# re-runs the second, which has no network at all (mvn -o, --network=none).
WORKDIR /build
COPY reporter/pom.xml ./pom.xml
RUN mvn -q -B -Diceberg.version=${ICEBERG_VERSION} dependency:go-offline package
COPY reporter/src ./src
RUN --network=none mvn -o -q -B -Diceberg.version=${ICEBERG_VERSION} package \
    && cp target/openlineage-metrics-reporter-1.0.0.jar /openlineage-metrics-reporter.jar

# ---------------------------------------------------------------------
# Stage 2: Spark + Iceberg runtime + the reporter jar.
#
# Spark 4.0 (not 3.5.4 like preflight/docker/spark) deliberately: Stage 03
# needs a real VARIANT column, and VARIANT/PARSE_JSON only exist starting
# Spark 4.0. This image is independent of preflight's throwaway Spark image
# and does not affect it. Base image already ships Java 17 (Spark 4 dropped
# Java 11 support), so no JDK-override hack is needed here.
# ---------------------------------------------------------------------
FROM apache/spark:4.0.0-scala2.13-java17-python3-ubuntu

ARG ICEBERG_VERSION=1.11.0
ARG SPARK_MAJOR_MINOR=4.0
ARG SPARK_SCALA_VERSION=2.13

USER root

RUN curl -fsSL -o "/opt/spark/jars/iceberg-spark-runtime-${SPARK_MAJOR_MINOR}_${SPARK_SCALA_VERSION}-${ICEBERG_VERSION}.jar" \
      "https://repo1.maven.org/maven2/org/apache/iceberg/iceberg-spark-runtime-${SPARK_MAJOR_MINOR}_${SPARK_SCALA_VERSION}/${ICEBERG_VERSION}/iceberg-spark-runtime-${SPARK_MAJOR_MINOR}_${SPARK_SCALA_VERSION}-${ICEBERG_VERSION}.jar" && \
    curl -fsSL -o "/opt/spark/jars/iceberg-aws-bundle-${ICEBERG_VERSION}.jar" \
      "https://repo1.maven.org/maven2/org/apache/iceberg/iceberg-aws-bundle/${ICEBERG_VERSION}/iceberg-aws-bundle-${ICEBERG_VERSION}.jar"

COPY --from=reporter-build /openlineage-metrics-reporter.jar /opt/spark/jars/openlineage-metrics-reporter.jar

# Config ARGs are declared only here, after the downloads: a changed build arg
# (e.g. switching CATALOG_* in .env) invalidates every RUN after its ARG, and
# declared above the curl it would re-download the jars -- impossible offline.
ARG MINIO_ROOT_USER=minioadmin
ARG MINIO_ROOT_PASSWORD=minioadmin123
ARG MINIO_ENDPOINT=http://minio:9000
ARG ICEBERG_REST_URI=http://iceberg-rest:8181
ARG ICEBERG_WAREHOUSE=s3://warehouse/
# OAuth client credentials ("id:secret") + scope, for catalogs that need them
# (Apache Polaris); empty for Lakekeeper and the reference REST catalog
ARG CATALOG_CREDENTIAL=
ARG CATALOG_SCOPE=
ARG AWS_REGION=us-east-1
ARG OPENLINEAGE_URL=http://openlineage-collector:5000/api/v1/lineage
ARG OPENLINEAGE_NAMESPACE=row-level-lineage-demo

# OPENLINEAGE_URL / OPENLINEAGE_NAMESPACE are read by the reporter jar from
# the environment at report() time (set as container env vars in
# docker-compose.yml, not baked in here) so they can be overridden per-run
# without a rebuild.
ENV OPENLINEAGE_URL=${OPENLINEAGE_URL}
ENV OPENLINEAGE_NAMESPACE=${OPENLINEAGE_NAMESPACE}

RUN --network=none mkdir -p /opt/spark/conf && cat <<EOF > /opt/spark/conf/spark-defaults.conf
spark.sql.extensions org.apache.iceberg.spark.extensions.IcebergSparkSessionExtensions
spark.sql.catalog.lake org.apache.iceberg.spark.SparkCatalog
spark.sql.catalog.lake.type rest
spark.sql.catalog.lake.uri ${ICEBERG_REST_URI}
spark.sql.catalog.lake.warehouse ${ICEBERG_WAREHOUSE}
spark.sql.catalog.lake.io-impl org.apache.iceberg.aws.s3.S3FileIO
spark.sql.catalog.lake.s3.endpoint ${MINIO_ENDPOINT}
spark.sql.catalog.lake.s3.path-style-access true
spark.sql.catalog.lake.s3.access-key-id ${MINIO_ROOT_USER}
spark.sql.catalog.lake.s3.secret-access-key ${MINIO_ROOT_PASSWORD}
spark.sql.catalog.lake.client.region ${AWS_REGION}
spark.sql.catalog.lake.metrics-reporter-impl com.demo.lineage.OpenLineageMetricsReporter
spark.sql.catalog.lake.rest-metrics-reporting-enabled false
spark.sql.defaultCatalog lake
spark.hadoop.fs.s3a.endpoint ${MINIO_ENDPOINT}
spark.hadoop.fs.s3a.path.style.access true
spark.hadoop.fs.s3a.access.key ${MINIO_ROOT_USER}
spark.hadoop.fs.s3a.secret.key ${MINIO_ROOT_PASSWORD}
spark.driver.extraJavaOptions -Daws.region=${AWS_REGION}
EOF
# rest-metrics-reporting-enabled false (above): Iceberg's REST client also
# POSTs every commit's metrics report to the catalog's /metrics endpoint;
# Polaris refuses it for our principal (ForbiddenException + stack trace on
# every commit). The lineage events come from metrics-reporter-impl, not that.
# OAuth: auth type and token URI set explicitly (otherwise two WARN lines per run).
RUN --network=none if [ -n "${CATALOG_CREDENTIAL}" ]; then \
      printf 'spark.sql.catalog.lake.credential %s\nspark.sql.catalog.lake.scope %s\nspark.sql.catalog.lake.rest.auth.type oauth2\nspark.sql.catalog.lake.oauth2-server-uri %s/v1/oauth/tokens\n' \
        "${CATALOG_CREDENTIAL}" "${CATALOG_SCOPE}" "${ICEBERG_REST_URI}" >> /opt/spark/conf/spark-defaults.conf; \
    fi
# Errors only on the console: the demo's terminals show results, not Spark's
# WARN chatter (NativeCodeLoader, ObjectStore, ...)
RUN --network=none printf 'rootLogger.level = error\nrootLogger.appenderRef.stdout.ref = console\nappender.console.type = Console\nappender.console.name = console\nappender.console.target = SYSTEM_ERR\nappender.console.layout.type = PatternLayout\nappender.console.layout.pattern = %%d{yy/MM/dd HH:mm:ss} %%p %%c{1}: %%m%%n\n' \
      > /opt/spark/conf/log4j2.properties

# demo-spark-sql / demo-spark-submit: Spark's own tools minus the start-up
# noise neither can switch off -- the JVM's "Using incubator modules" warning
# (Spark 4 loads jdk.incubator.vector itself) and the SQL shell's banner (log
# level hint, Web UI, master). Everything else, errors included, passes
# through, and the tool's exit code is kept.
RUN --network=none for tool in spark-sql spark-submit; do \
      printf '%s\n' '#!/usr/bin/env bash' \
        "/opt/spark/bin/${tool} \"\$@\" 2>&1 | grep --line-buffered -vE '^(WARNING: Using incubator modules|Setting default log level to|To adjust logging level use|Spark Web UI available at|Spark master: )'" \
        'exit ${PIPESTATUS[0]}' > "/usr/local/bin/demo-${tool}"; \
      chmod +x "/usr/local/bin/demo-${tool}"; \
    done

WORKDIR /work
