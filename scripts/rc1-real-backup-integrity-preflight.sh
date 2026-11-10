#!/usr/bin/env bash
# GST Fleetbase RC1 local backup integrity preflight. READ-ONLY.
# Reads encrypted Restic pack data and streams three SQL gzip archives to gzip -t.
# Does not export SQL, connect to MySQL, restore files, or use an offsite network.
set -euo pipefail
if [[ "$(uname -s)" != Linux || "$(id -u)" -ne 0 ]]; then
  echo "RC1_BACKUP_INTEGRITY=NO_GO_UNSUPPORTED_CONTEXT"
  exit 2
fi
export RESTIC_REPOSITORY=/root/gstfleet-secure-repository
export RESTIC_PASSWORD_FILE=/root/gstfleet-secure-repository.password
for path in "$RESTIC_REPOSITORY/config" "$RESTIC_PASSWORD_FILE"; do
  if [[ ! -f "$path" ]]; then
    echo "RC1_BACKUP_INTEGRITY=NO_GO_MISSING_REPOSITORY_OR_CREDENTIAL"
    exit 2
  fi
done
command -v restic >/dev/null
command -v gzip >/dev/null
command -v python3 >/dev/null
command -v timeout >/dev/null
echo "RC1_RESTIC_READ_DATA_CHECK=START"
if command -v ionice >/dev/null 2>&1; then
  ionice -c 3 nice -n 15 timeout 120s restic --no-lock check --read-data
else
  nice -n 15 timeout 120s restic --no-lock check --read-data
fi
echo "RC1_RESTIC_READ_DATA_CHECK=PASS"
# Pin to one snapshot ID: do not let rotating 'latest' select different backups
# between discovery and streaming if backup timer happens to run concurrently.
snapshot=$(restic --no-lock snapshots --json | python3 -c '
import json,sys
a=json.load(sys.stdin)
a=[x for x in a if "gstfleet-daily" in x.get("tags",[])]
assert a, "No daily snapshot"
print(max(a,key=lambda x:x["time"])["id"])
')
for name in fleetbase fleetbase_sandbox fleetbase_storefront; do
  path=$(restic --no-lock ls "$snapshot" --json | python3 -c '
import json,sys
name=sys.argv[1]
hits=[]
for line in sys.stdin:
    try: x=json.loads(line)
    except ValueError: continue
    p=x.get("path","")
    if x.get("struct_type")=="node" and p.endswith("/"+name+".sql.gz") and "/.gstfleet-daily-dump." in p:
        hits.append(p)
assert len(hits)==1, "Missing or duplicate compressed SQL dump"
print(hits[0])
' "$name")
  restic --no-lock dump "$snapshot" "$path" | gzip -t
  echo "RC1_${name}_GZIP_CRC=PASS"
done
echo "RC1_THREE_DB_BACKUP_COMPRESSED_INTEGRITY=PASS"
echo "RC1_SQL_IMPORT_AND_APP_ROLLBACK=NOT_TESTED"
echo "RC1_PRODUCTION_APPROVAL=NO_GO"
