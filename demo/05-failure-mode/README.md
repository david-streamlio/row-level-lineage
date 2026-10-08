# Stage 05 -- Failure mode (closer)

**The one point this proves:** the most-deployed streaming UPSERT pattern
(equality-delete, as used by Flink's `BaseEqualityDeltaWriter` and most CDC
sinks) produces no usable row lineage -- `_row_id` churns on every update,
even on a table that otherwise fully supports row lineage.

## Run it

```
demo/run-stage.sh 5
```

## What happens

1. Creates `failure_demo.customers_v2_reference` (format-version **2**,
   never written to) purely so `DESCRIBE TABLE EXTENDED` shows there is no
   `_row_id` column at all pre-V3.
2. Creates `failure_demo.customers_equality_upsert` as **V3, from scratch**
   (consistent with this repo's "always create V3 from scratch" guardrail --
   this table fully supports row lineage).
3. Runs 3 rounds of `DELETE FROM ... WHERE customer_id = X; INSERT INTO ...`
   against the same `customer_id` -- an equality-delete-then-insert, the
   same *observable* pattern as an equality-delete-based streaming upsert.
4. Reads `_row_id` after each round via DuckDB.

Expect: `_row_id` **changes every round** for the same `customer_id` --
contrast directly with Stage 02, where the same 3-update scenario against a
position-delete `MERGE` keeps `_row_id` constant.

## Why this is scripted Spark, not live Flink

The task's own spec explicitly allows this fallback: *"If too fragile live,
produce a scripted reproducible before/after capture + spec paragraph as
comment."* Standing up a Flink JobManager/TaskManager, checkpointing, and
the Iceberg Flink connector on top of everything else in this stack is a lot
of additional live-demo surface area for a closer stage whose entire point
is a **negative** result. The `DELETE`+`INSERT` sequence here reproduces the
exact same underlying cause Flink's `BaseEqualityDeltaWriter` hits: an
equality-condition delete has no positional correlation to the row it
"replaces", so Iceberg allocates a fresh `_row_id` for the insert every
time. A real Flink pipeline would show the identical number-churning result,
just with more moving parts on stage.

**Spec paragraph (what a live Flink version would look like):** a Flink SQL
job with `'connector'='iceberg'`, an upsert-mode table
(`'write.upsert.enabled'='true'`) keyed on `customer_id`, consuming a CDC
topic. Flink's `BaseEqualityDeltaWriter` handles each update by writing an
equality-delete file (`customer_id = X`) plus a fresh data file for the new
row values. Read the resulting table in Spark or DuckDB (**never Flink** --
Flink's Iceberg source can't project `_row_id` either) and `_row_id` for
`customer_id = X` will be different after every checkpoint that touched it.

### Guardrail note

The reference table above is intentionally format-version 2 -- this is the
one deliberate exception to "create all demo tables as V3 from scratch",
because Stage 05 needs a V2 table to exist as the negative baseline. It is
never written to and never upgraded to V3.
