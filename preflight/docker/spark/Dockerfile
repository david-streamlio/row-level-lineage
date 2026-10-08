# Throwaway Spark container. Used ONLY for:
#   1. Explicit V3 table DDL (CREATE TABLE ... TBLPROPERTIES format-version=3)
#   2. Check C fallback (reading bronze.events.snapshots) if DuckDB can't.
# NEVER used to read _row_id: Spark's Iceberg source has no
# SupportsReadingMetadata for row-lineage metadata columns.
FROM apache/spark:3.5.4

ARG ICEBERG_VERSION=1.11.0
ARG SPARK_MAJOR_MINOR=3.5
ARG SPARK_SCALA_VERSION=2.12
ARG MINIO_ROOT_USER=minioadmin
ARG MINIO_ROOT_PASSWORD=minioadmin123
ARG MINIO_ENDPOINT=http://minio:9000
ARG ICEBERG_REST_URI=http://iceberg-rest:8181
ARG ICEBERG_WAREHOUSE=s3://warehouse/
ARG AWS_REGION=us-east-1

USER root

# The apache/spark:3.5.4 base image ships Java 11, but iceberg-spark-runtime
# 1.11.0 is compiled for Java 17 (class file version 61) -- loading it under
# Java 11 fails with UnsupportedClassVersionError. Install a Java 17 JRE
# alongside the base image's Java 11 and point JAVA_HOME at a stable
# architecture-independent symlink; Spark 3.5.x itself runs fine on 17.
RUN apt-get update -qq && \
    apt-get install -y --no-install-recommends openjdk-17-jdk-headless && \
    rm -rf /var/lib/apt/lists/* && \
    ln -s "$(dirname "$(dirname "$(readlink -f /usr/bin/javac)")")" /opt/java17
ENV JAVA_HOME=/opt/java17
ENV PATH="/opt/java17/bin:${PATH}"

RUN curl -fsSL -o "/opt/spark/jars/iceberg-spark-runtime-${SPARK_MAJOR_MINOR}_${SPARK_SCALA_VERSION}-${ICEBERG_VERSION}.jar" \
      "https://repo1.maven.org/maven2/org/apache/iceberg/iceberg-spark-runtime-${SPARK_MAJOR_MINOR}_${SPARK_SCALA_VERSION}/${ICEBERG_VERSION}/iceberg-spark-runtime-${SPARK_MAJOR_MINOR}_${SPARK_SCALA_VERSION}-${ICEBERG_VERSION}.jar" && \
    curl -fsSL -o "/opt/spark/jars/iceberg-aws-bundle-${ICEBERG_VERSION}.jar" \
      "https://repo1.maven.org/maven2/org/apache/iceberg/iceberg-aws-bundle/${ICEBERG_VERSION}/iceberg-aws-bundle-${ICEBERG_VERSION}.jar"

# spark.sql.defaultCatalog=lake lets every SQL file reference tables as
# `bronze.events` (no catalog prefix), matching the queries in this repo's
# sql/*.sql verbatim.
RUN mkdir -p /opt/spark/conf && cat <<EOF > /opt/spark/conf/spark-defaults.conf
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
spark.sql.defaultCatalog lake
spark.hadoop.fs.s3a.endpoint ${MINIO_ENDPOINT}
spark.hadoop.fs.s3a.path.style.access true
spark.hadoop.fs.s3a.access.key ${MINIO_ROOT_USER}
spark.hadoop.fs.s3a.secret.key ${MINIO_ROOT_PASSWORD}
spark.driver.extraJavaOptions -Daws.region=${AWS_REGION}
EOF

WORKDIR /work
