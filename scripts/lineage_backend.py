#!/usr/bin/env python3
"""
Backend adapter shared by the demo read scripts and the dashboard.

Every row-lineage read in this repo follows the same two steps:

  1. Ask the catalog for a table's metadata.json (location + contents).
  2. Point DuckDB's iceberg_scan() at that exact metadata.json, with an S3
     secret that can read the warehouse.

Only those two steps differ between running locally (MinIO + this repo's
Iceberg REST catalog) and running on AWS (S3 + Glue Data Catalog), so they
live here behind one interface. Select with LINEAGE_BACKEND=local|aws
(default: local).

  local  GET {CATALOG_URI}/v1/{prefix}/namespaces/{ns}/tables/{t} against
         the demo's REST catalog (Lakekeeper by default, or preflight's
         reference server -- see CATALOG_* in .env); {prefix} comes from
         GET /v1/config?warehouse={CATALOG_WAREHOUSE} (Lakekeeper's warehouse
         id, empty for the reference server). DuckDB secret uses MinIO's
         root credentials, path-style URLs, no SSL.
  aws    glue.get_table() -> Parameters["metadata_location"], then read that
         metadata.json from S3 directly. Deliberately NOT Glue's Iceberg
         REST endpoint, which would require SigV4 request signing. DuckDB
         secret uses the AWS credential chain (profile / env / instance
         role) -- no keys in .env. LINEAGE_NAMESPACE_PREFIX (e.g. "rll_")
         maps demo namespaces to Glue database names (bronze -> rll_bronze)
         so a shared account shows what the databases belong to.
"""
import gzip
import json
import os
import urllib.error
import urllib.parse
import urllib.request


class TableNotFound(LookupError):
    """namespace.table doesn't exist in the selected catalog."""


def get_backend():
    name = os.environ.get("LINEAGE_BACKEND", "local").strip().lower()
    if name == "local":
        return LocalRestBackend()
    if name == "aws":
        return GlueBackend()
    raise ValueError(f"LINEAGE_BACKEND must be 'local' or 'aws', got {name!r}")


def _duckdb_with_iceberg():
    import duckdb

    con = duckdb.connect()
    con.execute("INSTALL httpfs; LOAD httpfs;")
    con.execute("INSTALL iceberg; LOAD iceberg;")
    return con


class LocalRestBackend:
    """MinIO + the demo's Iceberg REST catalog (Polaris, Lakekeeper or the reference server)."""

    name = "local"

    def __init__(self):
        self.rest_uri = os.environ.get("CATALOG_URI") or os.environ["ICEBERG_REST_URI"]
        self.warehouse = os.environ.get("CATALOG_WAREHOUSE", "")
        # "client_id:secret" for catalogs that require OAuth (Apache Polaris)
        self.credential = os.environ.get("CATALOG_CREDENTIAL", "")
        self.scope = os.environ.get("CATALOG_SCOPE", "")
        self._base = None
        self._token = None

    def _open(self, url: str):
        """urlopen with the catalog's OAuth token, when it needs one."""
        request = urllib.request.Request(url)
        if self.credential:
            if self._token is None:
                client_id, secret = self.credential.split(":", 1)
                body = urllib.parse.urlencode({"grant_type": "client_credentials", "client_id": client_id,
                                               "client_secret": secret, "scope": self.scope}).encode()
                with urllib.request.urlopen(f"{self.rest_uri}/v1/oauth/tokens", data=body, timeout=15) as resp:
                    self._token = json.loads(resp.read())["access_token"]
            request.add_header("Authorization", f"Bearer {self._token}")
        return urllib.request.urlopen(request, timeout=15)

    @property
    def base(self) -> str:
        """{CATALOG_URI}/v1[/{prefix}], the prefix resolved once from /v1/config."""
        if self._base is None:
            query = f"?warehouse={urllib.parse.quote(self.warehouse)}" if self.warehouse else ""
            with self._open(f"{self.rest_uri}/v1/config{query}") as resp:
                config = json.loads(resp.read())
            prefix = config.get("overrides", {}).get("prefix") or config.get("defaults", {}).get("prefix")
            self._base = f"{self.rest_uri}/v1" + (f"/{prefix}" if prefix else "")
        return self._base

    def catalog_namespace(self, namespace: str) -> str:
        """The namespace as the catalog names it (unchanged locally)."""
        return namespace

    def list_tables(self) -> list[tuple[str, str]]:
        """Every (namespace, table) in the catalog (single-level namespaces)."""
        def get(path):
            with self._open(f"{self.base}{path}") as resp:
                return json.loads(resp.read())

        tables = []
        for ns in get("/namespaces").get("namespaces", []):
            name = ".".join(ns)
            for ident in get(f"/namespaces/{name}/tables").get("identifiers", []):
                tables.append((name, ident["name"]))
        return sorted(tables)

    def load_table(self, namespace: str, table: str) -> tuple[str, dict]:
        """Return (metadata_location, metadata) for namespace.table."""
        url = f"{self.base}/namespaces/{namespace}/tables/{table}"
        try:
            with self._open(url) as resp:
                body = json.loads(resp.read())
        except urllib.error.HTTPError as exc:
            if exc.code == 404:
                raise TableNotFound(f"{namespace}.{table}") from exc
            raise
        return body["metadata-location"], body["metadata"]

    def duckdb_connect(self):
        # Credentials are read here rather than in __init__ so metadata-only
        # callers (table_stats.py) don't need MinIO env vars.
        con = _duckdb_with_iceberg()
        con.execute(
            f"""
            CREATE SECRET minio_s3 (
                TYPE S3, KEY_ID '{os.environ["MINIO_ROOT_USER"]}',
                SECRET '{os.environ["MINIO_ROOT_PASSWORD"]}',
                ENDPOINT '{os.environ["MINIO_ENDPOINT"]}', URL_STYLE 'path',
                USE_SSL false, REGION '{os.environ.get("AWS_REGION", "us-east-1")}'
            );
            """
        )
        return con


class GlueBackend:
    """Real S3 + the Glue Data Catalog (Iceberg tables written by GlueCatalog)."""

    name = "aws"

    def __init__(self):
        # Imported lazily so the local backend works in images without boto3.
        import boto3

        # LINEAGE_AWS_REGION first: in this repo AWS_REGION is MinIO's placeholder.
        self.region = os.environ.get("LINEAGE_AWS_REGION") or os.environ.get("AWS_REGION", "us-east-1")
        self.prefix = os.environ.get("LINEAGE_NAMESPACE_PREFIX", "")
        self.glue = boto3.client("glue", region_name=self.region)
        self.s3 = boto3.client("s3", region_name=self.region)

    def catalog_namespace(self, namespace: str) -> str:
        """The Glue database for a demo namespace (bronze -> rll_bronze)."""
        return namespace if namespace.startswith(self.prefix) else self.prefix + namespace

    def list_tables(self) -> list[tuple[str, str]]:
        """Every Iceberg (namespace, table) in this demo's Glue databases.

        Namespaces come back without LINEAGE_NAMESPACE_PREFIX (rll_bronze ->
        bronze), matching how the rest of the demo names them.
        """
        tables = []
        for page in self.glue.get_paginator("get_databases").paginate():
            for db in page["DatabaseList"]:
                if not db["Name"].startswith(self.prefix):
                    continue  # shared account: only this demo's databases
                for tpage in self.glue.get_paginator("get_tables").paginate(DatabaseName=db["Name"]):
                    for t in tpage["TableList"]:
                        if t.get("Parameters", {}).get("table_type", "").upper() == "ICEBERG":
                            tables.append((db["Name"][len(self.prefix):], t["Name"]))
        return sorted(tables)

    def load_table(self, namespace: str, table: str) -> tuple[str, dict]:
        """Return (metadata_location, metadata) for namespace.table.

        The Glue database name is the Iceberg namespace (bronze, silver, ...)
        plus LINEAGE_NAMESPACE_PREFIX. Already-prefixed names (as reported in
        lineage events) are used as-is.
        """
        database = self.catalog_namespace(namespace)
        try:
            resp = self.glue.get_table(DatabaseName=database, Name=table)
        except self.glue.exceptions.EntityNotFoundException as exc:
            raise TableNotFound(f"{database}.{table}") from exc
        params = resp["Table"].get("Parameters", {})
        metadata_location = params.get("metadata_location")
        if not metadata_location:
            raise RuntimeError(
                f"{database}.{table} has no 'metadata_location' parameter in Glue -- "
                f"is it an Iceberg table? (table_type={params.get('table_type')!r})"
            )
        bucket, key = _split_s3_uri(metadata_location)
        raw = self.s3.get_object(Bucket=bucket, Key=key)["Body"].read()
        # write.metadata.compression-codec=gzip produces *.gz.metadata.json
        if raw[:2] == b"\x1f\x8b":
            raw = gzip.decompress(raw)
        return metadata_location, json.loads(raw)

    def duckdb_connect(self):
        con = _duckdb_with_iceberg()
        con.execute("INSTALL aws; LOAD aws;")
        con.execute(
            f"CREATE SECRET aws_s3 (TYPE S3, PROVIDER credential_chain, REGION '{self.region}');"
        )
        return con


def _split_s3_uri(uri: str) -> tuple[str, str]:
    for prefix in ("s3://", "s3a://", "s3n://"):
        if uri.startswith(prefix):
            bucket, _, key = uri[len(prefix):].partition("/")
            return bucket, key
    raise ValueError(f"not an S3 URI: {uri}")
