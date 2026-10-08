-- VARIANT: for drift nobody modeled in advance -- an arbitrary
-- semi-structured payload the producer starts sending mid-stream, stored
-- without a fixed relational schema. Requires Spark 4.0 (VARIANT/PARSE_JSON
-- do not exist in Spark 3.5), which is why demo/ uses spark-demo rather
-- than preflight's Spark 3.5.4 image for this stage.
ALTER TABLE bronze.events
  ADD COLUMN raw_payload VARIANT;

DESCRIBE TABLE EXTENDED bronze.events;
