# Live demo dashboard: read-only JSON API + static page.
#
# duckdb is pinned to the version preflight's duckdb image resolved to
# (1.5.5) so the dashboard and the stage scripts read row lineage through
# the same iceberg extension behavior. boto3 is only used when
# LINEAGE_BACKEND=aws; kafka-python only for the local pipeline view.
FROM python:3.11-slim

RUN pip install --no-cache-dir "duckdb==1.5.5" "boto3>=1.34" "kafka-python>=2.0.6"

# Pre-install the DuckDB extensions so the first request doesn't download them.
RUN python3 -c "import duckdb; c = duckdb.connect(); [c.execute(f'INSTALL {e}') for e in ('httpfs', 'avro', 'iceberg', 'aws')]"

WORKDIR /app
# dashboard/ and scripts/ are bind-mounted by docker-compose.yml, so edits to
# server.py, static/ or lineage_backend.py only need a container restart.
ENTRYPOINT ["python3", "/app/dashboard/server.py"]
