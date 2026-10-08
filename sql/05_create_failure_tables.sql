-- Two tables for Stage 05:
--
-- 1. failure_demo.customers_v2_reference (V2): created ONLY to show, via
--    DESCRIBE, that _row_id doesn't exist as a concept at all pre-V3. No
--    data is ever written to it.
--
-- 2. failure_demo.customers_equality_upsert (V3, from scratch -- consistent
--    with the "always V3" guardrail): the actual failure-mode subject. It
--    HAS row lineage available, but we upsert into it using an
--    equality-delete pattern (DELETE-by-key, then INSERT) -- functionally
--    the same shape as Flink's BaseEqualityDeltaWriter upsert, which deletes
--    by equality condition rather than by row position. Iceberg has no way
--    to correlate an equality-deleted row with its replacement insert, so
--    every "update" allocates a brand-new _row_id. Using a V3 table for this
--    (rather than literally V2) makes the failure visible as a NUMBER
--    changing on screen, instead of a column simply not existing -- a much
--    stronger live-demo moment for the same underlying point. See
--    demo/05-failure-mode/README.md for the full rationale and the
--    literal-Flink alternative.
CREATE NAMESPACE IF NOT EXISTS failure_demo;

CREATE TABLE IF NOT EXISTS failure_demo.customers_v2_reference (
  customer_id BIGINT,
  total_amount DECIMAL(12,2)
)
USING iceberg
TBLPROPERTIES (
  'format-version' = '2',
  'write.format.default' = 'parquet'
);

DESCRIBE TABLE EXTENDED failure_demo.customers_v2_reference;

CREATE TABLE IF NOT EXISTS failure_demo.customers_equality_upsert (
  customer_id   BIGINT,
  total_amount  DECIMAL(12,2),
  last_event_id STRING,
  updated_ts    TIMESTAMP
)
USING iceberg
TBLPROPERTIES (
  'format-version'       = '3',
  'write.format.default' = 'parquet'
);

DESCRIBE TABLE EXTENDED failure_demo.customers_equality_upsert;
