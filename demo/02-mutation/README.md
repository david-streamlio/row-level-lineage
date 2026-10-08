# Stage 02 -- Mutation with deletion vectors

**The one point this proves:** identity survives mutation only on the
deletion-vector (position-delete) path. `silver.customers` is
merge-on-read; when Spark's `MERGE` updates an existing row via a position
delete, Iceberg copies the old row's `_row_id` forward and only advances
`_last_updated_sequence_number`.

## Run it

```
demo/run-stage.sh 2
```

## What happens

1. Creates `silver.customers` as V3, merge-on-read
   (`write.delete/update/merge.mode = merge-on-read`).
2. Runs 3 separate `MERGE` commits against the **same** `customer_id`.
3. After each commit, reads `_row_id` / `_last_updated_sequence_number` for
   that customer via DuckDB.

Expect: `_row_id` **constant** across all 3 rounds; `_last_updated_sequence_number`
**advances** each round. Contrast with Stage 05, where the same 3-update
scenario against an equality-delete upsert path churns `_row_id` every time.
