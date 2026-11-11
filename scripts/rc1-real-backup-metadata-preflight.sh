#!/usr/bin/env bash
# GST Fleetbase RC1 — backup readiness inventory, READ-ONLY.
# Never restore data, connect to live MySQL, print credentials, or contact B2.
set -euo pipefail

if [[ "$(uname -s)" != Linux || "$(id -u)" != 0 ]]; then
  echo "RC1_BACKUP_PREFLIGHT=NO_GO_UNSUPPORTED_CONTEXT"
  exit 2
fi

repo=/root/gstfleet-secure-repository
passfile=/root/gstfleet-secure-repository.password
fail=0

require() {
  local label="$1" ok="$2"
  if [[ "$ok" == 1 ]]; then
    printf '%s=PASS\n' "$label"
  else
    printf '%s=NO_GO\n' "$label"
    fail=1
  fi
}

for unit in gstfleet-backup.service gstfleet-offsite.service; do
  state=$(systemctl show "$unit" -p Result --value 2>/dev/null || true)
  status=$(systemctl show "$unit" -p ExecMainStatus --value 2>/dev/null || true)
  stamp=$(systemctl show "$unit" -p InactiveExitTimestamp --value 2>/dev/null || true)
  if [[ -z "$stamp" || "$stamp" == n/a ]]; then
    stamp=$(systemctl show "$unit" -p InactiveEnterTimestamp --value 2>/dev/null || true)
  fi
  recent=0
  if [[ -n "$stamp" && "$stamp" != n/a ]]; then
    unix=$(date -d "$stamp" +%s 2>/dev/null || echo 0)
    now=$(date +%s)
    if (( unix > 0 && now >= unix && now-unix <= 129600 )); then recent=1; fi
  fi
  label=$(echo "$unit" | tr '.-' '__' | tr '[:lower:]' '[:upper:]')
  require "RC1_${label}_SUCCESS" "$([[ "$state" == success && "$status" == 0 ]] && echo 1 || echo 0)"
  require "RC1_${label}_WITHIN_36_HOURS" "$recent"
done

require "RC1_LOCAL_RESTIC_REPOSITORY_EXISTS" "$([[ -f "$repo/config" && -d "$repo/snapshots" && -f "$passfile" ]] && echo 1 || echo 0)"
if ! command -v restic >/dev/null 2>&1; then
  echo "RC1_LOCAL_RESTIC_SNAPSHOT_METADATA=NO_GO_RESTIC_MISSING"
  fail=1
elif [[ -f "$repo/config" && -f "$passfile" ]]; then
  # No credentials or snapshot details are printed. Only counts and age.
  if summary=$(restic -r "$repo" -p "$passfile" snapshots --json 2>/dev/null | python3 -c '
import json,sys,datetime
data=json.load(sys.stdin)
assert isinstance(data,list) and data
times=[]
for x in data:
    s=x.get("time","")
    if s:
        times.append(datetime.datetime.fromisoformat(s.replace("Z","+00:00")).timestamp())
assert times
age=(datetime.datetime.now(datetime.timezone.utc).timestamp()-max(times))/3600
print("%d %.1f" % (len(data),age))
' 2>/dev/null); then
    count=${summary%% *}
    age=${summary#* }
    echo "RC1_LOCAL_RESTIC_SNAPSHOT_COUNT=$count"
    echo "RC1_LOCAL_RESTIC_NEWEST_SNAPSHOT_AGE_HOURS=$age"
    require "RC1_LOCAL_RESTIC_SNAPSHOT_WITHIN_36_HOURS" "$(awk -v age="$age" 'BEGIN {print (age>=0 && age<=36)?1:0}')"
  else
    echo "RC1_LOCAL_RESTIC_SNAPSHOT_METADATA=NO_GO_UNREADABLE"
    fail=1
  fi
fi

echo "RC1_OFFSITE_CONTENT_INSPECTION=NOT_ATTEMPTED"
echo "RC1_REAL_BACKUP_RESTORE=NOT_TESTED"
echo "RC1_RELEASE_ISOLATION=NOT_ATTESTED"
if (( fail != 0 )); then
  echo "RC1_BACKUP_READINESS=NO_GO"
  exit 2
fi
echo "RC1_BACKUP_METADATA_READINESS=PASS_RESTORE_STILL_REQUIRED"
