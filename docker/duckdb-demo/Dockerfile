# Same base as preflight/docker/duckdb (DuckDB is the only engine that can
# select _row_id / _last_updated_sequence_number), plus DuckDB's httpfs,
# avro (needed by iceberg), iceberg and aws extensions installed at build time. Without this every
# container start downloads them from extensions.duckdb.org, so the stage
# reads and the demo/sql.sh query window fail on a venue network without
# internet. LOAD / INSTALL in lineage_backend.py then resolve locally.
FROM python:3.11-slim

RUN pip install --no-cache-dir "duckdb==1.5.6" pandas boto3 \
    && python3 -c "import duckdb; [duckdb.execute(f'INSTALL {e}') for e in ('httpfs', 'avro', 'iceberg', 'aws')]"

WORKDIR /work
