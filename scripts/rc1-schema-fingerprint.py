#!/usr/bin/env python3
"""Fail-closed structural fingerprint for RC1 S7 disposable MySQL schemas.

Prints only SHA-256 of sorted metadata (table/column/index/FK). No row data.
"""
import hashlib
import re
import subprocess
import sys

if len(sys.argv) != 2 or not re.fullmatch(
    r"gst_rc1_(?:s4_upgrade|s7_recovered)(?:_sandbox|_storefront)?", sys.argv[1]
):
    raise SystemExit("STOP=S7_UNAUTHORIZED_SCHEMA_NAME")

db = sys.argv[1]
# Every result is schema-relative: database name does not affect the digest.
# Preserve nullable/default/extra, collation, index order and FK actions.
sql = f"""
SELECT CONCAT_WS('|','T',table_name,table_type,COALESCE(engine,'-'),
  COALESCE(table_collation,'-'))
FROM information_schema.tables WHERE table_schema='{db}'
UNION ALL
SELECT CONCAT_WS('|','C',table_name,ordinal_position,column_name,column_type,
  is_nullable,COALESCE(column_default,'<NULL>'),extra,COALESCE(collation_name,'-'),
  COALESCE(generation_expression,'-'))
FROM information_schema.columns WHERE table_schema='{db}'
UNION ALL
SELECT CONCAT_WS('|','I',table_name,index_name,non_unique,seq_in_index,
  column_name,COALESCE(sub_part,0),index_type,COALESCE(collation,'-'))
FROM information_schema.statistics WHERE table_schema='{db}'
UNION ALL
SELECT CONCAT_WS('|','K',table_name,constraint_name,column_name,ordinal_position,
  referenced_table_name,referenced_column_name)
FROM information_schema.key_column_usage
WHERE table_schema='{db}' AND referenced_table_name IS NOT NULL
UNION ALL
SELECT CONCAT_WS('|','R',constraint_name,table_name,referenced_table_name,
  update_rule,delete_rule)
FROM information_schema.referential_constraints
WHERE constraint_schema='{db}'
"""
p = subprocess.run(
    ["mysql", "-h", "127.0.0.1", "-uroot", "-N", "-B", "--raw"],
    input=sql,
    text=True,
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
    check=False,
)
if p.returncode != 0:
    raise SystemExit("STOP=S7_METADATA_QUERY_FAILED")
rows = sorted(x for x in p.stdout.splitlines() if x.strip())
if not rows or len(rows) < 100:
    raise SystemExit("STOP=S7_METADATA_INCOMPLETE")
print(hashlib.sha256(("\n".join(rows) + "\n").encode()).hexdigest())
