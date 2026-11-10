#!/usr/bin/env bash
# GST Fleetbase RC1 — one-time PRIVATE SQL restore proof.
# Restores an existing encrypted daily snapshot to an isolated, memory-capped,
# networkless MySQL container; never connects to production MySQL.
# Destroys the disposable container on exit. No output contains user data.
set -euo pipefail
umask 077

if [[ "$(uname -s)" != Linux || "$(id -u)" -ne 0 ]]; then
  echo "RC1_RESTORE=NO_GO_NOT_ROOT_LINUX"; exit 2
fi
for command in docker restic gzip python3 awk timeout; do
  if ! command -v "$command" >/dev/null 2>&1; then
    echo "RC1_RESTORE=NO_GO_MISSING_TOOL_$command"; exit 2
  fi
done

repo=/root/gstfleet-secure-repository
passfile=/root/gstfleet-secure-repository.password
image=mysql:8.0-oracle
expected_image=sha256:6cd09145362dfe6831b14545de3d5fd6cc75c37cfd6ef8561429c1fc73518b39

[[ -f "$repo/config" && -f "$passfile" ]] || { echo "RC1_RESTORE=NO_GO_BACKUP_UNAVAILABLE"; exit 2; }
actual_image=$(docker image inspect "$image" --format '{{.Id}}' 2>/dev/null || true)
[[ "$actual_image" == "$expected_image" ]] || { echo "RC1_RESTORE=NO_GO_IMAGE_PIN_MISMATCH"; exit 2; }
available_kib=$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)
(( available_kib >= 5242880 )) || { echo "RC1_RESTORE=NO_GO_HOST_RAM_BELOW_5_GIB"; exit 2; }
[[ -z "$(docker ps -a --format '{{.Names}}' | grep '^gst-rc1-private-restore-' || true)" ]] || {
  echo "RC1_RESTORE=NO_GO_OTHER_LAB_EXISTS"; exit 2;
}
[[ "$(docker inspect gstfleet-database-1 --format '{{.State.Running}} {{.State.Health.Status}}' 2>/dev/null)" == "true healthy" ]] || {
  echo "RC1_RESTORE=NO_GO_PRODUCTION_DB_NOT_HEALTHY"; exit 2;
}
export RESTIC_REPOSITORY="$repo" RESTIC_PASSWORD_FILE="$passfile"
snapshot=$(restic --no-lock snapshots --json | python3 -c '
import json,sys
daily=[s for s in json.load(sys.stdin) if "gstfleet-daily" in s.get("tags",[])]
assert daily, "No daily snapshot"
print(max(daily,key=lambda s:s["time"])["id"])
')
echo "RC1_RESTORE_SNAPSHOT_PREFIX=${snapshot:0:12}"
container="gst-rc1-private-restore-$$"
cleanup() {
  docker rm -f "$container" >/dev/null 2>&1 || true
  echo "RC1_RESTORE_LAB_CLEANUP=ATTEMPTED"
}
trap cleanup EXIT INT TERM HUP

echo "RC1_RESTORE_LAB_START=NETWORK_NONE_MEMORY_1G_TMPFS_512M"
docker run -d --rm --name "$container" --network none \
  --memory 1g --memory-swap 1g --cpus 1 --pids-limit 128 \
  --security-opt no-new-privileges --read-only \
  --tmpfs /var/lib/mysql:rw,nosuid,nodev,size=512m,mode=1777 \
  --tmpfs /var/run/mysqld:rw,nosuid,nodev,size=32m,mode=1777 \
  --tmpfs /tmp:rw,nosuid,nodev,size=64m,mode=1777 \
  --env MYSQL_ALLOW_EMPTY_PASSWORD=yes \
  "$image" --skip-networking --skip-name-resolve >/dev/null

net=$(docker inspect "$container" --format '{{.HostConfig.NetworkMode}}')
published=$(docker inspect "$container" --format '{{json .HostConfig.PortBindings}}')
mem=$(docker inspect "$container" --format '{{.HostConfig.Memory}}')
read_only=$(docker inspect "$container" --format '{{.HostConfig.ReadonlyRootfs}}')
[[ "$net" == none && "$published" == null && "$mem" == 1073741824 && "$read_only" == true ]] || {
  echo "RC1_RESTORE=NO_GO_ISOLATION_CONTRACT"; exit 2;
}
echo "RC1_RESTORE_ISOLATION=PASS"

ready=0
for i in $(seq 1 90); do
  if docker exec "$container" mysqladmin --protocol=socket -uroot ping >/dev/null 2>&1; then ready=1; break; fi
  if [[ "$(docker inspect "$container" --format '{{.State.Running}}' 2>/dev/null || true)" != true ]]; then break; fi
  sleep 1
done
[[ "$ready" == 1 ]] || { echo "RC1_RESTORE=NO_GO_MYSQL_TEMP_START"; exit 2; }
echo "RC1_RESTORE_MYSQL_READY=PASS"

for pair in fleetbase:152 fleetbase_sandbox:138 fleetbase_storefront:33; do
  name=${pair%%:*}; expected=${pair##*:}
  path=$(restic --no-lock ls "$snapshot" --json | python3 -c '
import json,sys
name=sys.argv[1]
hits=[]
for line in sys.stdin:
    try: node=json.loads(line)
    except ValueError: continue
    p=node.get("path","")
    if node.get("struct_type")=="node" and p.endswith("/"+name+".sql.gz") and "/.gstfleet-daily-dump." in p:
        hits.append(p)
assert len(hits)==1, "Expected exactly one backup dump"
print(hits[0])
' "$name")
  docker exec "$container" mysql --protocol=socket -uroot -e "CREATE DATABASE \`$name\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" >/dev/null 2>&1
  echo "RC1_RESTORE_IMPORT_START=$name"
  # Suppress SQL/record-level diagnostic output; fail closed on errors.
  if ! restic --no-lock dump "$snapshot" "$path" | gzip -dc | \
    docker exec -i "$container" mysql --protocol=socket -uroot "$name" >/dev/null 2>/dev/null; then
    echo "RC1_RESTORE_IMPORT_$name=NO_GO"
    exit 2
  fi
  tables=$(docker exec "$container" mysql --protocol=socket -uroot -N -B -e \
    "SELECT COUNT(*) FROM information_schema.tables WHERE TABLE_SCHEMA='$name' AND TABLE_TYPE='BASE TABLE';")
  [[ "$tables" == "$expected" ]] || { echo "RC1_RESTORE_TABLE_COUNT_$name=NO_GO"; exit 2; }
  echo "RC1_RESTORE_IMPORT_$name=PASS"
  echo "RC1_RESTORE_TABLE_COUNT_$name=$tables"
done

echo "RC1_REAL_THREE_DB_IMPORT=PASS_ISOLATED"
echo "RC1_LARAVEL12_REAL_DATA_UPGRADE=NOT_RUN"
echo "RC1_FULL_APP_ROLLBACK=NOT_RUN"
echo "RC1_PRODUCTION=NO_GO"
