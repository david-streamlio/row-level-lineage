# DuckDB is the read/verification engine for this harness: it can select
# _row_id / _last_updated_sequence_number (SupportsReadingMetadata).
# Flink deliberately is NOT used here for reads -- it cannot select those
# columns.
FROM python:3.11-slim

RUN pip install --no-cache-dir "duckdb>=1.1.0" pandas

WORKDIR /work
