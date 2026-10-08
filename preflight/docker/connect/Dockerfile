# ---------------------------------------------------------------------------
# Stage 1: resolve the Iceberg Kafka Connect sink's runtime classpath.
#
# Apache Iceberg does not publish a shaded "iceberg-kafka-connect-runtime"
# jar to Maven Central (that only existed for the pre-donation Tabular
# project). `iceberg-kafka-connect` 1.11.0 is a plain jar, so we resolve its
# full dependency tree with Maven and drop the resulting jars into a plugin
# directory -- Kafka Connect's plugin.path scanner accepts a directory of
# jars just as well as a single fat jar.
# ---------------------------------------------------------------------------
FROM maven:3.9-eclipse-temurin-17 AS deps

ARG ICEBERG_VERSION=1.11.0
ARG KAFKA_VERSION=3.7.0
ARG JACKSON_VERSION=2.21.3
ARG JACKSON_ANNOTATIONS_VERSION=2.21
ARG HADOOP_VERSION=3.4.3

WORKDIR /build
COPY pom.xml /build/pom.xml

RUN mvn -q -B -f /build/pom.xml \
      -Diceberg.version="${ICEBERG_VERSION}" \
      -Dkafka.version="${KAFKA_VERSION}" \
      -Djackson.version="${JACKSON_VERSION}" \
      -Djackson.annotations.version="${JACKSON_ANNOTATIONS_VERSION}" \
      -Dhadoop.version="${HADOOP_VERSION}" \
      dependency:copy-dependencies -DoutputDirectory=/plugin -DincludeScope=runtime

# ---------------------------------------------------------------------------
# Stage 2: runtime image -- plain Kafka distribution + the resolved plugin.
# ---------------------------------------------------------------------------
FROM eclipse-temurin:17-jre-jammy

ARG KAFKA_VERSION=3.7.0
ARG KAFKA_SCALA_VERSION=2.13
ARG ICEBERG_VERSION=1.11.0
ARG ICEBERG_MIN_VERSION=1.10.0

RUN apt-get update && \
    apt-get install -y --no-install-recommends curl unzip ca-certificates && \
    rm -rf /var/lib/apt/lists/*

# Plain Kafka distribution (gives us connect-distributed.sh + kafka-topics.sh
# etc.) pulled from the permanent Apache archive rather than downloads.apache.org
# (which only mirrors the latest releases) for long-term reproducibility.
RUN curl -fsSL "https://archive.apache.org/dist/kafka/${KAFKA_VERSION}/kafka_${KAFKA_SCALA_VERSION}-${KAFKA_VERSION}.tgz" -o /tmp/kafka.tgz && \
    mkdir -p /opt/kafka && \
    tar -xzf /tmp/kafka.tgz -C /opt/kafka --strip-components=1 && \
    rm /tmp/kafka.tgz

ENV KAFKA_HOME=/opt/kafka
ENV PATH="${KAFKA_HOME}/bin:${PATH}"

COPY --from=deps /plugin /opt/kafka/plugins/iceberg-kafka-connect/

ENV ICEBERG_VERSION=${ICEBERG_VERSION}
ENV ICEBERG_MIN_VERSION=${ICEBERG_MIN_VERSION}

COPY connect-distributed.properties /opt/kafka/config/connect-distributed.properties
COPY check_iceberg_version.sh /usr/local/bin/check_iceberg_version.sh
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /usr/local/bin/check_iceberg_version.sh /entrypoint.sh

EXPOSE 8083
ENTRYPOINT ["/entrypoint.sh"]
