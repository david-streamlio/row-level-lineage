-- Seeds the AWS backend (S3 + Glue Data Catalog) with the same three tables
-- the local demo builds, so the dashboard can be checked with
-- LINEAGE_BACKEND=aws. Run through spark-demo with the `glue` catalog that
-- scripts/aws/seed_glue_tables.sh configures on the command line.
--
-- Namespaces carry the rll_ prefix (LINEAGE_NAMESPACE_PREFIX) so they're
-- recognizable in a shared account. Tables are created V3 from scratch, as in
-- every local stage. The CREATEs are idempotent; the INSERT/MERGE/DELETE
-- statements are not -- re-running adds more commits (harmless, but the
-- identity charts grow).

CREATE NAMESPACE IF NOT EXISTS glue.rll_bronze;
CREATE NAMESPACE IF NOT EXISTS glue.rll_silver;
CREATE NAMESPACE IF NOT EXISTS glue.rll_failure_demo;

-- Stage 01 shape: two append commits, so first-row-id continuation is visible.
CREATE TABLE IF NOT EXISTS glue.rll_bronze.events (
  event_id    STRING,
  customer_id BIGINT,
  amount      DECIMAL(12,2),
  ts          TIMESTAMP
)
USING iceberg
TBLPROPERTIES ('format-version' = '3', 'write.format.default' = 'parquet');

INSERT INTO glue.rll_bronze.events VALUES
  ('aws-0001', 101, 12.50, TIMESTAMP '2026-10-06 09:00:00'),
  ('aws-0002', 102, 99.99, TIMESTAMP '2026-10-06 09:00:01'),
  ('aws-0003', 103,  5.00, TIMESTAMP '2026-10-06 09:00:02');
INSERT INTO glue.rll_bronze.events VALUES
  ('aws-0004', 104, 42.00, TIMESTAMP '2026-10-06 09:00:03'),
  ('aws-0005', 105, 18.25, TIMESTAMP '2026-10-06 09:00:04');

-- Stage 02 shape: merge-on-read, three MERGE commits on the same customer.
CREATE TABLE IF NOT EXISTS glue.rll_silver.customers (
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

MERGE INTO glue.rll_silver.customers t
USING (SELECT 9001 AS customer_id, CAST(10.00 AS DECIMAL(12,2)) AS amount, 'aws-m1' AS event_id, TIMESTAMP '2026-10-06 09:01:00' AS ts) s
ON t.customer_id = s.customer_id
WHEN MATCHED THEN UPDATE SET t.total_amount = t.total_amount + s.amount, t.last_event_id = s.event_id, t.updated_ts = s.ts
WHEN NOT MATCHED THEN INSERT (customer_id, total_amount, last_event_id, updated_ts) VALUES (s.customer_id, s.amount, s.event_id, s.ts);

MERGE INTO glue.rll_silver.customers t
USING (SELECT 9001 AS customer_id, CAST(20.00 AS DECIMAL(12,2)) AS amount, 'aws-m2' AS event_id, TIMESTAMP '2026-10-06 09:02:00' AS ts) s
ON t.customer_id = s.customer_id
WHEN MATCHED THEN UPDATE SET t.total_amount = t.total_amount + s.amount, t.last_event_id = s.event_id, t.updated_ts = s.ts
WHEN NOT MATCHED THEN INSERT (customer_id, total_amount, last_event_id, updated_ts) VALUES (s.customer_id, s.amount, s.event_id, s.ts);

MERGE INTO glue.rll_silver.customers t
USING (SELECT 9001 AS customer_id, CAST(30.00 AS DECIMAL(12,2)) AS amount, 'aws-m3' AS event_id, TIMESTAMP '2026-10-06 09:03:00' AS ts) s
ON t.customer_id = s.customer_id
WHEN MATCHED THEN UPDATE SET t.total_amount = t.total_amount + s.amount, t.last_event_id = s.event_id, t.updated_ts = s.ts
WHEN NOT MATCHED THEN INSERT (customer_id, total_amount, last_event_id, updated_ts) VALUES (s.customer_id, s.amount, s.event_id, s.ts);

-- Stage 05 shape: delete by key, then insert -- three rounds.
CREATE TABLE IF NOT EXISTS glue.rll_failure_demo.customers_equality_upsert (
  customer_id   BIGINT,
  total_amount  DECIMAL(12,2),
  last_event_id STRING,
  updated_ts    TIMESTAMP
)
USING iceberg
TBLPROPERTIES ('format-version' = '3', 'write.format.default' = 'parquet');

DELETE FROM glue.rll_failure_demo.customers_equality_upsert WHERE customer_id = 9500;
INSERT INTO glue.rll_failure_demo.customers_equality_upsert VALUES (9500, 10.00, 'aws-u1', TIMESTAMP '2026-10-06 09:04:00');
DELETE FROM glue.rll_failure_demo.customers_equality_upsert WHERE customer_id = 9500;
INSERT INTO glue.rll_failure_demo.customers_equality_upsert VALUES (9500, 20.00, 'aws-u2', TIMESTAMP '2026-10-06 09:05:00');
DELETE FROM glue.rll_failure_demo.customers_equality_upsert WHERE customer_id = 9500;
INSERT INTO glue.rll_failure_demo.customers_equality_upsert VALUES (9500, 30.00, 'aws-u3', TIMESTAMP '2026-10-06 09:06:00');

SHOW TABLES IN glue.rll_silver;
SELECT customer_id, total_amount, last_event_id FROM glue.rll_silver.customers;
