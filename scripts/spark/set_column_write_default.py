#!/usr/bin/env python3
"""Change a column's write-default only, via Iceberg's Java API.

Same reason as add_column_with_default.py: Spark SQL's ALTER TABLE ...
ALTER COLUMN ... SET DEFAULT path goes through the same Spark3Util
ColumnDefaultValue handling that's unsupported in Iceberg 1.11.0's Spark
integration. UpdateSchema.updateColumnDefault(name, literal) changes only
the write-default -- historical rows keep reading their original
initial-default, which is the whole point of this step.

Usage: set_column_write_default.py <catalog.namespace.table> <column> <new_default_value>
"""
import sys

from pyspark.sql import SparkSession


def main():
    if len(sys.argv) != 4:
        print(f"Usage: {sys.argv[0]} <catalog.namespace.table> <column> <new_default_value>", file=sys.stderr)
        sys.exit(1)

    table_name, column, new_default = sys.argv[1:4]

    spark = SparkSession.builder.getOrCreate()
    jvm = spark._jvm

    table = jvm.org.apache.iceberg.spark.Spark3Util.loadIcebergTable(spark._jsparkSession, table_name)
    default_literal = jvm.org.apache.iceberg.expressions.Literal.of(new_default)

    table.updateSchema().updateColumnDefault(column, default_literal).commit()

    print(f"Changed write-default for '{column}' on {table_name} to '{new_default}' "
          f"(historical rows keep reading their original initial-default)")

    spark.stop()


if __name__ == "__main__":
    main()
