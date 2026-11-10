#!/usr/bin/env bash
# GST Fleetbase RC1: private, one-shot restoration of three genuine DB dumps.
# All MySQL data is ephemeral RAM only. No public port, network, SQL disclosure,
# production DB connection, shared project mount, or durable MySQL volume.
set -euo pipefail
umask 077

if [[ "$(uname -s)" != Linux || "$(id -u)" -ne 0 ]]; then
  echo "RC1_RESTORE=NO_GO_NOT_ROOT_LINUX"; exit 2
fi
for command in docker restic gzip python3 awk; do
  command -v "$command" >/dev/null 2>&1 || { echo "RC1_RESTORE=NO_GO_MISSING_TOOL_$command"; exit 2; }
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
error_log=""
cleanup() {
  [[ -z "$error_log" ]] || rm -f "$error_log"
  docker rm -f "$container" >/dev/null 2>&1 || true
  echo "RC1_RESTORE_LAB_CLEANUP=ATTEMPTED"
}
trap cleanup EXIT INT TERM HUP

echo "RC1_RESTORE_LAB_START=NETWORK_NONE_MEMORY_1536M_TMPFS_768M"
docker run -d --rm --name "$container" --network none \
  --memory 1536m --memory-swap 1536m --cpus 1 --pids-limit 128 \
  --security-opt no-new-privileges --read-only \
  --tmpfs /var/lib/mysql:rw,nosuid,nodev,size=768m,mode=1777 \
  --tmpfs /var/run/mysqld:rw,nosuid,nodev,size=32m,mode=1777 \
  --tmpfs /tmp:rw,nosuid,nodev,size=64m,mode=1777 \
  --env MYSQL_ALLOW_EMPTY_PASSWORD=yes \
  "$image" --skip-networking --skip-name-resolve >/dev/null

net=$(docker inspect "$container" --format '{{.HostConfig.NetworkMode}}')
published=$(docker inspect "$container" --format '{{json .HostConfig.PortBindings}}')
mem=$(docker inspect "$container" --format '{{.HostConfig.Memory}}')
readonly=$(docker inspect "$container" --format '{{.HostConfig.ReadonlyRootfs}}')
[[ "$net" == none && ( "$published" == "{}" || "$published" == null ) && "$mem" == 1610612736 && "$readonly" == true ]] || {
  echo "RC1_RESTORE=NO_GO_ISOLATION_CONTRACT"; exit 2;
}
echo "RC1_RESTORE_ISOLATION=PASS"

# Critical: mysql Docker entrypoint first starts a TEMPORARY server for initialization,
# intentionally shuts it down and starts FINAL mysqld. A mysqladmin ping to the
# temporary server would cause ERROR 2013 during an import. Require the final
# entrypoint completion marker AND a responsive socket before proceeding.
ready=0
for i in $(seq 1 90); do
  if docker logs "$container" 2>&1 | grep -F 'MySQL init process done. Ready for start up.' >/dev/null; then
    if docker exec "$container" mysqladmin --protocol=socket -uroot ping >/dev/null 2>&1; then
      ready=1
      break
    fi
  fi
  [[ "$(docker inspect "$container" --format '{{.State.Running}}' 2>/dev/null || true)" == true ]] || break
  sleep 1
done
[[ "$ready" == 1 ]] || { echo "RC1_RESTORE=NO_GO_MYSQL_FINAL_START"; exit 2; }
echo "RC1_RESTORE_MYSQL_FINAL_START=PASS"

for pair in fleetbase:152 fleetbase_sandbox:138 fleetbase_storefront:33; do
  name=${pair%%:*}
  expected=${pair##*:}
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
assert len(hits)==1, "Expected one matching database dump"
print(hits[0])
' "$name")
  docker exec "$container" mysql --protocol=socket -uroot -e "CREATE DATABASE \`$name\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" >/dev/null 2>&1
  echo "RC1_RESTORE_IMPORT_START=$name"
  error_log=$(mktemp /dev/shm/gst-rc1-import-error.XXXXXXXX)
  if ! restic --no-lock dump "$snapshot" "$path" | gzip -dc | \
    docker exec -i "$container" mysql --protocol=socket -uroot "$name" >/dev/null 2>"$error_log"; then
    code=$(grep -m 1 -Eo 'ERROR [0-9]+' "$error_log" || true)
    line=$(grep -m 1 -Eo 'at line [0-9]+' "$error_log" || true)
    echo "RC1_RESTORE_IMPORT_$name=NO_GO"
    echo "RC1_RESTORE_MYSQL_ERROR_CODE=${code:-UNCLASSIFIED}"
    echo "RC1_RESTORE_MYSQL_ERROR_LINE=${line:-NOT_REPORTED}"
    exit 2
  fi
  rm -f "$error_log"
  error_log=""
  tables=$(docker exec "$container" mysql --protocol=socket -uroot -N -B -e \
    "SELECT COUNT(*) FROM information_schema.tables WHERE TABLE_SCHEMA='$name' AND TABLE_TYPE='BASE TABLE';")
  [[ "$tables" == "$expected" ]] || { echo "RC1_RESTORE_TABLE_COUNT_$name=NO_GO"; exit 2; }
  echo "RC1_RESTORE_IMPORT_$name=PASS"
  echo "RC1_RESTORE_TABLE_COUNT_$name=$tables"

  # Attest reference metadata and migration registry on the restored copy.
  # These database metadata queries return only aggregate integers.
  meta=$(docker exec "$container" mysql --protocol=socket -uroot -N -B -e "
    SELECT COUNT(DISTINCT TABLE_NAME)
      FROM information_schema.statistics
      WHERE TABLE_SCHEMA='$name';
    SELECT COUNT(*)
      FROM information_schema.referential_constraints
      WHERE CONSTRAINT_SCHEMA='$name';
    SELECT COUNT(*)
      FROM information_schema.triggers
      WHERE TRIGGER_SCHEMA='$name';
  ")
  indexes=$(printf '%s\n' "$meta" | sed -n '1p')
  fks=$(printf '%s\n' "$meta" | sed -n '2p')
  triggers=$(printf '%s\n' "$meta" | sed -n '3p')
  [[ "$indexes" =~ ^[0-9]+$ && "$fks" =~ ^[0-9]+$ && "$triggers" =~ ^[0-9]+$ ]] || {
    echo "RC1_RESTORE_METADATA_$name=NO_GO"; exit 2;
  }
  echo "RC1_RESTORE_INDEXED_TABLE_COUNT_$name=$indexes"
  echo "RC1_RESTORE_FOREIGN_KEY_COUNT_$name=$fks"
  echo "RC1_RESTORE_TRIGGER_COUNT_$name=$triggers"

  case "$name" in
    fleetbase) expected_migrations=394 ;;
    fleetbase_sandbox) expected_migrations=304 ;;
    fleetbase_storefront) expected_migrations=NONE ;;
  esac
  migration_table=$(docker exec "$container" mysql --protocol=socket -uroot -N -B -e "
    SELECT COUNT(*) FROM information_schema.tables
    WHERE TABLE_SCHEMA='$name' AND TABLE_NAME='migrations';
  ")
  if [[ "$expected_migrations" == NONE ]]; then
    [[ "$migration_table" == 0 ]] || { echo "RC1_RESTORE_MIGRATION_REGISTRY_$name=NO_GO_UNEXPECTED_TABLE"; exit 2; }
    echo "RC1_RESTORE_MIGRATION_REGISTRY_$name=ABSENT_EXPECTED"
  else
    [[ "$migration_table" == 1 ]] || { echo "RC1_RESTORE_MIGRATION_REGISTRY_$name=NO_GO_MISSING_TABLE"; exit 2; }
    migrations=$(docker exec "$container" mysql --protocol=socket -uroot -N -B -e "SELECT COUNT(*) FROM \`$name\`.migrations;")
    [[ "$migrations" == "$expected_migrations" ]] || {
      echo "RC1_RESTORE_MIGRATION_REGISTRY_$name=NO_GO_COUNT_MISMATCH"
      echo "RC1_RESTORE_MIGRATION_RECORDS_$name=$migrations"
      exit 2
    }
    echo "RC1_RESTORE_MIGRATION_RECORDS_$name=$migrations"
    echo "RC1_RESTORE_MIGRATION_REGISTRY_$name=PASS"
  fi
done

echo "RC1_REAL_THREE_DB_IMPORT=PASS_ISOLATED"
echo "RC1_LARAVEL12_REAL_DATA_UPGRADE=NOT_RUN"
echo "RC1_FULL_APP_ROLLBACK=NOT_RUN"
echo "RC1_PRODUCTION=NO_GO"
