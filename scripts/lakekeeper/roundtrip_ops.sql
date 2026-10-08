-- V3 round-trip operations, run identically against each catalog
-- (__C__ is replaced with the catalog name by v3_roundtrip.sh).
-- Fixed values and timestamps so both catalogs end with identical data.
CREATE NAMESPACE IF NOT EXISTS __C__.rt;
-- __PURGE__ is PURGE for the reference catalog and empty for Lakekeeper,
-- which deletes a dropped table's files itself (Spark's PURGE races it).
DROP TABLE IF EXISTS __C__.rt.customers __PURGE__;

CREATE TABLE __C__.rt.customers (
  customer_id   BIGINT,
  total_amount  DECIMAL(12,2),
  last_event_id STRING,
  updated_ts    TIMESTAMP
)
USING iceberg
TBLPROPERTIES (
  'format-version'       = '3',
  'write.format.default' = 'parquet',
  'write.delete.mode'    = 'merge-on-read',
  'write.update.mode'    = 'merge-on-read',
  'write.merge.mode'     = 'merge-on-read'
);

INSERT INTO __C__.rt.customers VALUES
  (1, 10.00, 'e1', TIMESTAMP '2026-01-01 00:00:00'),
  (2, 20.00, 'e2', TIMESTAMP '2026-01-01 00:00:00'),
  (3, 30.00, 'e3', TIMESTAMP '2026-01-01 00:00:00');

-- two updates of customer 2 (deletion-vector path keeps _row_id)
MERGE INTO __C__.rt.customers t
USING (SELECT 2 AS customer_id, CAST(5.00 AS DECIMAL(12,2)) AS amount, 'e4' AS event_id, TIMESTAMP '2026-01-02 00:00:00' AS ts) s
ON t.customer_id = s.customer_id
WHEN MATCHED THEN UPDATE SET total_amount = t.total_amount + s.amount, last_event_id = s.event_id, updated_ts = s.ts
WHEN NOT MATCHED THEN INSERT (customer_id, total_amount, last_event_id, updated_ts) VALUES (s.customer_id, s.amount, s.event_id, s.ts);

MERGE INTO __C__.rt.customers t
USING (SELECT 2 AS customer_id, CAST(7.00 AS DECIMAL(12,2)) AS amount, 'e5' AS event_id, TIMESTAMP '2026-01-03 00:00:00' AS ts) s
ON t.customer_id = s.customer_id
WHEN MATCHED THEN UPDATE SET total_amount = t.total_amount + s.amount, last_event_id = s.event_id, updated_ts = s.ts
WHEN NOT MATCHED THEN INSERT (customer_id, total_amount, last_event_id, updated_ts) VALUES (s.customer_id, s.amount, s.event_id, s.ts);

-- a MERGE that inserts (new customer 4)
MERGE INTO __C__.rt.customers t
USING (SELECT 4 AS customer_id, CAST(40.00 AS DECIMAL(12,2)) AS amount, 'e6' AS event_id, TIMESTAMP '2026-01-04 00:00:00' AS ts) s
ON t.customer_id = s.customer_id
WHEN MATCHED THEN UPDATE SET total_amount = t.total_amount + s.amount, last_event_id = s.event_id, updated_ts = s.ts
WHEN NOT MATCHED THEN INSERT (customer_id, total_amount, last_event_id, updated_ts) VALUES (s.customer_id, s.amount, s.event_id, s.ts);

DELETE FROM __C__.rt.customers WHERE customer_id = 3;
