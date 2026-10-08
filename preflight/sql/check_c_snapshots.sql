-- Check C fallback (Spark), used only if DuckDB's iceberg_snapshots() build
-- doesn't expose first_row_id/added_rows for this DuckDB version.
-- PASS = first_row_id advances by added_rows on each successive commit.
SELECT snapshot_id, sequence_number, first_row_id, added_rows, operation
FROM bronze.events.snapshots
ORDER BY committed_at;
