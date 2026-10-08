package com.demo.lineage;

import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.time.Duration;
import java.time.Instant;
import java.util.UUID;

import org.apache.iceberg.metrics.CommitReport;
import org.apache.iceberg.metrics.MetricsReport;
import org.apache.iceberg.metrics.MetricsReporter;

/**
 * Wired in via the Iceberg catalog property "metrics-reporter-impl". Iceberg
 * calls report(MetricsReport) synchronously on the driver after every table
 * commit; we filter to CommitReport (the only variant carrying snapshotId /
 * sequenceNumber / operation) and POST a minimal OpenLineage-shaped RunEvent
 * to the demo's collector. This is the graph-level half of Composable
 * Lineage -- Iceberg's row-level identity (_row_id) is never visible here,
 * which is exactly the gap Stage 04 bridges via the sequenceNumber join.
 *
 * The same jar runs in two writers: spark-demo and Kafka Connect's Iceberg
 * sink (compose.connect-lineage.yml). Each sets its own job identity and
 * inputs through the environment, so Marquez draws one graph:
 *   kafka topic -> kafka-connect job -> bronze.events <- spark jobs
 * Dataset names drop the writer's catalog name ("lake" in Spark, "iceberg"
 * in Connect) so both writers land on the same Marquez node.
 */
public class OpenLineageMetricsReporter implements MetricsReporter {

  private static final HttpClient CLIENT = HttpClient.newHttpClient();
  private static final String PRODUCER = "urn:row-level-lineage-demo:openlineage-metrics-reporter";

  private final String collectorUrl =
      System.getenv().getOrDefault("OPENLINEAGE_URL", "http://openlineage-collector:5000/api/v1/lineage");
  private final String namespace =
      System.getenv().getOrDefault("OPENLINEAGE_NAMESPACE", "row-level-lineage-demo");
  // Optional fixed job name (Connect: "iceberg-sink"); default "<table>.commit".
  private final String jobName = System.getenv("OPENLINEAGE_JOB_NAME");
  // Optional inputs, "namespace|name" pairs separated by commas
  // (Connect: "kafka://kafka:9092|events"; Spark's MERGE into silver: bronze.events).
  // A commit never lists its own output table as an input, so one Spark run can
  // insert into bronze and MERGE from it into silver without a bronze self-loop.
  private final String inputs = System.getenv().getOrDefault("OPENLINEAGE_INPUTS", "");
  private final String datasetNamespace =
      System.getenv().getOrDefault("OPENLINEAGE_DATASET_NAMESPACE", "iceberg");

  public OpenLineageMetricsReporter() {
  }

  @Override
  public void report(MetricsReport report) {
    if (!(report instanceof CommitReport)) {
      return;
    }
    CommitReport commit = (CommitReport) report;
    try {
      String runId = UUID.randomUUID().toString();
      String json = toRunEventJson(commit, runId);
      HttpRequest request =
          HttpRequest.newBuilder(URI.create(collectorUrl))
              .header("Content-Type", "application/json")
              .timeout(Duration.ofSeconds(5))
              .POST(HttpRequest.BodyPublishers.ofString(json))
              .build();
      CLIENT.send(request, HttpResponse.BodyHandlers.discarding());
    } catch (Exception e) {
      System.err.println("[OpenLineageMetricsReporter] failed to emit event: " + e);
    }
  }

  private String toRunEventJson(CommitReport commit, String runId) {
    String tableName = escape(commit.tableName());
    String operation = escape(commit.operation());
    Long snapshotId = commit.snapshotId();
    Long sequenceNumber = commit.sequenceNumber();
    String now = Instant.now().toString();
    String job = jobName == null || jobName.isEmpty() ? tableName + ".commit" : escape(jobName);

    return "{"
        + "\"eventType\":\"COMPLETE\","
        + "\"eventTime\":\"" + now + "\","
        + "\"producer\":\"" + PRODUCER + "\","
        + "\"schemaURL\":\"https://openlineage.io/spec/2-0-2/OpenLineage.json#/definitions/RunEvent\","
        + "\"job\":{\"namespace\":\"" + escape(namespace) + "\",\"name\":\"" + job + "\"},"
        + "\"inputs\":" + inputsJson(withoutCatalog(commit.tableName())) + ","
        + "\"outputs\":[" + dataset(datasetNamespace, withoutCatalog(commit.tableName())) + "],"
        + "\"run\":{"
        + "\"runId\":\"" + runId + "\","
        + "\"facets\":{"
        + "\"iceberg_commit\":{"
        + "\"_producer\":\"" + PRODUCER + "\","
        + "\"_schemaURL\":\"" + PRODUCER + ":IcebergCommitRunFacet\","
        + "\"tableName\":\"" + tableName + "\","
        + "\"snapshotId\":" + (snapshotId == null ? "null" : snapshotId) + ","
        + "\"sequenceNumber\":" + (sequenceNumber == null ? "null" : sequenceNumber) + ","
        + "\"operation\":\"" + operation + "\""
        + "}"
        + "}"
        + "}"
        + "}";
  }

  private String inputsJson(String outputName) {
    StringBuilder json = new StringBuilder("[");
    for (String pair : inputs.split(",")) {
      String[] parts = pair.trim().split("\\|", 2);
      if (parts.length != 2 || parts[1].equals(outputName)) {
        continue;
      }
      if (json.length() > 1) {
        json.append(',');
      }
      json.append(dataset(parts[0], parts[1]));
    }
    return json.append(']').toString();
  }

  private static String dataset(String datasetNamespace, String name) {
    return "{\"namespace\":\"" + escape(datasetNamespace) + "\",\"name\":\"" + escape(name) + "\"}";
  }

  /** "lake.bronze.events" -> "bronze.events"; names without a catalog pass through. */
  private static String withoutCatalog(String tableName) {
    if (tableName == null) {
      return "";
    }
    String[] parts = tableName.split("\\.");
    return parts.length >= 3 ? tableName.substring(parts[0].length() + 1) : tableName;
  }

  private static String escape(String value) {
    if (value == null) {
      return "";
    }
    return value.replace("\\", "\\\\").replace("\"", "\\\"");
  }
}
