-- Explicit V3 table creation. auto-create is disabled in the Kafka Connect
-- sink config (iceberg.tables.auto-create-enabled=false) precisely because
-- auto-create paths almost certainly produce a V2 table.
CREATE NAMESPACE IF NOT EXISTS bronze;

CREATE TABLE IF NOT EXISTS bronze.events (
  event_id    STRING,
  customer_id BIGINT,
  amount      DECIMAL(12,2),
  ts          TIMESTAMP
)
USING iceberg
TBLPROPERTIES (
  'format-version'        = '3',
  'write.format.default'  = 'parquet'
);

DESCRIBE TABLE EXTENDED bronze.events;
