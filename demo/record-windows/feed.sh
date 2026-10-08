#!/usr/bin/env bash
# Recorded window: the lineage feed -- one line per Iceberg commit (Kafka
# Connect and Spark) from openlineage-collector. Follows new lines only;
# reattaches if the collector restarts.
#
# Each collector line ("COMPLETE job=... table=lake.silver.customers
# operation=overwrite snapshotId=... sequenceNumber=4 runId=...", ~200 chars)
# is shown compact so it fits a half-screen pane without wrapping:
#   sequenceNumber=4   silver.customers   overwrite   Spark
# (catalog prefix dropped; the writer named from the job: iceberg-sink = Kafka
# Connect, <table>.commit = Spark). The full event stays in out/openlineage/.
bash "$(dirname "${BASH_SOURCE[0]}")/header.sh" "Lineage feed -- one OpenLineage event per Iceberg commit"
while :; do
  docker logs -f --tail 0 lineage-openlineage-collector 2>/dev/null \
    | awk '/^\[openlineage-collector\] (COMPLETE|START|FAIL)/ {
        job = table = op = seq = ""
        for (i = 1; i <= NF; i++) {
          if ($i ~ /^job=/) job = substr($i, 5)
          else if ($i ~ /^table=/) table = substr($i, 7)
          else if ($i ~ /^operation=/) op = substr($i, 11)
          else if ($i ~ /^sequenceNumber=/) seq = substr($i, 16)
        }
        sub(/^[^.]+\./, "", table)   # lake.silver.customers -> silver.customers
        writer = (job == "iceberg-sink") ? "Kafka Connect" : (job ~ /\.commit$/ ? "Spark" : job)
        printf "sequenceNumber=%-4s %-20s %-10s %s\n", seq, table, op, writer
        fflush()
      }'
  sleep 2
done
