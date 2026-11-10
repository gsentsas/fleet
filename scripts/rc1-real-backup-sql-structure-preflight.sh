#!/usr/bin/env bash
# GST Fleetbase RC1: READ-ONLY SQL dump structural attestations.
# Streams only from one pinned, encrypted daily Restic snapshot. Never prints SQL.
# Does not import SQL, launch Docker, connect to MySQL or change production.
set -euo pipefail
if [[ "$(uname -s)" != Linux || "$(id -u)" -ne 0 ]]; then
  echo "RC1_SQL_DUMP_STRUCTURE=NO_GO_UNSUPPORTED_CONTEXT"
  exit 2
fi
export RESTIC_REPOSITORY=/root/gstfleet-secure-repository
export RESTIC_PASSWORD_FILE=/root/gstfleet-secure-repository.password
for command in restic gzip python3; do
  if ! command -v "$command" >/dev/null 2>&1; then
    echo "RC1_SQL_DUMP_STRUCTURE=NO_GO_MISSING_TOOL"
    exit 2
  fi
done
snapshot=$(restic --no-lock snapshots --json | python3 -c '
import json,sys
daily=[s for s in json.load(sys.stdin) if "gstfleet-daily" in s.get("tags",[])]
assert daily, "No daily Restic backup"
print(max(daily,key=lambda s:s["time"])["id"])
')
echo "RC1_SQL_SNAPSHOT_ID_PREFIX=${snapshot:0:12}"
# The expected schema table counts are the previously audited live counts.
# Do not equate this to SQL validity, a real import, or row integrity.
for pair in fleetbase:152 fleetbase_sandbox:138 fleetbase_storefront:33; do
  name=${pair%%:*}
  expected=${pair##*:}
  path=$(restic --no-lock ls "$snapshot" --json | python3 -c '
import json,sys
name=sys.argv[1]
matches=[]
for line in sys.stdin:
    try: node=json.loads(line)
    except ValueError: continue
    p=node.get("path","")
    if node.get("struct_type")=="node" and p.endswith("/"+name+".sql.gz") and "/.gstfleet-daily-dump." in p:
        matches.append(p)
assert len(matches)==1, "Expected one dump for database"
print(matches[0])
' "$name")
  echo "RC1_SQL_DUMP_ANALYSIS_START=$name"
  restic --no-lock dump "$snapshot" "$path" | gzip -dc | python3 -c '
import sys
expected=int(sys.argv[1])
count={"create":0,"insert":0,"bytes":0,"lines":0}
for line in sys.stdin.buffer:
    count["bytes"]+=len(line)
    count["lines"]+=1
    stripped=line.lstrip().upper()
    if stripped.startswith(b"CREATE TABLE "): count["create"]+=1
    if stripped.startswith(b"INSERT INTO "): count["insert"]+=1
assert count["create"]==expected, "CREATE TABLE count differs from pinned baseline"
assert count["insert"]>0, "No row insertion statements in SQL dump"
assert count["bytes"]>1000 and count["lines"]>20, "Suspiciously small SQL dump"
print("RC1_SQL_CREATE_TABLE_COUNT=%d" % count["create"])
print("RC1_SQL_INSERT_STATEMENTS=%d" % count["insert"])
print("RC1_SQL_DECOMPRESSED_BYTES=%d" % count["bytes"])
' "$expected"
  echo "RC1_SQL_DUMP_STRUCTURE_$name=PASS"
done
echo "RC1_SQL_DUMP_THREE_DATABASES=PASS"
echo "RC1_REAL_SQL_IMPORT=NOT_TESTED"
echo "RC1_FULL_APP_ROLLBACK=NOT_TESTED"
echo "RC1_PRODUCTION_DECISION=NO_GO"
