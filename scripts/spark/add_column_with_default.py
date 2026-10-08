#!/usr/bin/env python3
"""Add a NOT NULL column with an initial-default via Iceberg's Java API.

Spark SQL's ALTER TABLE ... ADD COLUMN ... DEFAULT is rejected by Iceberg
1.11.0's Spark integration: Spark3Util.apply(AddColumn) throws
"Incompatible change: cannot add required column" for any non-nullable
column, and separately throws UnsupportedOperationException for any column
carrying a Spark ColumnDefaultValue at all ("setting default values in
Spark is currently unsupported"). The underlying Iceberg table API has
supported this since UpdateSchema.addRequiredColumn(name, type, default)
was added, so we go straight at that instead of through Spark SQL's DDL
grammar.

Usage: add_column_with_default.py <catalog.namespace.table> <column> <iceberg_type> <default_string_value> [required|optional]

required (default): NOT NULL column, UpdateSchema.addRequiredColumn.
optional: nullable column with the same initial-default / write-default,
UpdateSchema.addColumn(name, type, default) -- what Stage 03 uses, because
Iceberg 1.11's Kafka Connect sink doesn't apply write-defaults: a required
column it can't fill kills its task (NullPointerException converting the
record); an optional one it writes as NULL.
"""
import sys

from pyspark.sql import SparkSession

TYPE_MAP = {
    "STRING": lambda jvm: jvm.org.apache.iceberg.types.Types.StringType.get(),
}


def main():
    if len(sys.argv) not in (5, 6) or (len(sys.argv) == 6 and sys.argv[5] not in ("required", "optional")):
        print(f"Usage: {sys.argv[0]} <catalog.namespace.table> <column> <iceberg_type> <default_value> [required|optional]", file=sys.stderr)
        sys.exit(1)

    table_name, column, iceberg_type, default_value = sys.argv[1:5]
    required = len(sys.argv) == 5 or sys.argv[5] == "required"

    spark = SparkSession.builder.getOrCreate()
    jvm = spark._jvm

    if iceberg_type.upper() not in TYPE_MAP:
        print(f"Unsupported type: {iceberg_type}", file=sys.stderr)
        sys.exit(1)
    field_type = TYPE_MAP[iceberg_type.upper()](jvm)

    table = jvm.org.apache.iceberg.spark.Spark3Util.loadIcebergTable(spark._jsparkSession, table_name)
    default_literal = jvm.org.apache.iceberg.expressions.Literal.of(default_value)

    if required:
        table.updateSchema().addRequiredColumn(column, field_type, default_literal).commit()
    else:
        table.updateSchema().addColumn(column, field_type, default_literal).commit()

    print(f"Added {'required' if required else 'optional'} column '{column}' {iceberg_type} to {table_name} "
          f"with initial-default AND write-default = '{default_value}'")

    spark.stop()


if __name__ == "__main__":
    main()
