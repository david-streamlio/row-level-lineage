-- V3 from scratch, never a V2->V3 upgrade (that path leaves _row_id NULL).
-- merge-on-read is required for Stage 02: the DV (deletion-vector) path is
-- the only mutation path that preserves _row_id across an UPDATE/MERGE.
CREATE NAMESPACE IF NOT EXISTS silver;

CREATE TABLE IF NOT EXISTS silver.customers (
  customer_id   BIGINT,
  total_amount  DECIMAL(12,2),
  last_event_id STRING,
  updated_ts    TIMESTAMP
)
USING iceberg
TBLPROPERTIES (
  'format-version'              = '3',
  'write.format.default'        = 'parquet',
  'write.delete.mode'           = 'merge-on-read',
  'write.update.mode'           = 'merge-on-read',
  'write.merge.mode'            = 'merge-on-read'
);

DESCRIBE TABLE EXTENDED silver.customers;
