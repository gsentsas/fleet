#!/usr/bin/env bash
# GST Fleetbase RC1 — genuine Restic SQL -> isolated MySQL -> pinned Laravel12 migrations.
# No external network, ports, production DB access, host source changes or user data output.
set -euo pipefail
umask 077

if [[ "$(uname -s)" != Linux || "$(id -u)" -ne 0 ]]; then echo "RC1_REAL_L12=NO_GO_CONTEXT"; exit 2; fi
for dep in docker restic gzip python3 awk; do command -v "$dep" >/dev/null || { echo "RC1_REAL_L12=NO_GO_TOOL_$dep"; exit 2; }; done
export RESTIC_REPOSITORY=/root/gstfleet-secure-repository
export RESTIC_PASSWORD_FILE=/root/gstfleet-secure-repository.password
root=/root/.gst-rc1-runtime-31a6a026
api="$root/repo/api"
sha=31a6a026c7062b3febe2ff90d0927f16a74bf834
mysql_image=mysql:8.0-oracle
mysql_image_id=sha256:6cd09145362dfe6831b14545de3d5fd6cc75c37cfd6ef8561429c1fc73518b39
php_image=fleetbase/fleetbase-api:v0.7.75
if [[ ! -f "$api/vendor/autoload.php" || "$(cat "$root/VERIFIED_SOURCE")" != "$sha" ||
  "$(git -C "$root/repo" rev-parse HEAD)" != "$sha" ]]; then echo "RC1_REAL_L12=NO_GO_EXACT_VENDOR"; exit 2; fi
printf '%s  %s\n' 'be721c73404b686992d5971abe712ab2c373bd0e4ecc58bfb2d0a2021be5297c' "$api/composer.json" | sha256sum --check --status
printf '%s  %s\n' 'b73196821fe46d45eb8f4f9e2bd6b0df90a2e62d911b8f840c7fc243c94ba453' "$api/composer.lock" | sha256sum --check --status
[[ "$(docker image inspect "$mysql_image" --format '{{.Id}}' 2>/dev/null)" == "$mysql_image_id" ]] || { echo "RC1_REAL_L12=NO_GO_MYSQL_IMAGE"; exit 2; }
[[ "$(docker inspect gstfleet-database-1 --format '{{.State.Running}} {{.State.Health.Status}}' 2>/dev/null)" == "true healthy" ]] || { echo "RC1_REAL_L12=NO_GO_PROD_HEALTH"; exit 2; }
avail=$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)
(( avail > 5242880 )) || { echo "RC1_REAL_L12=NO_GO_MEMORY"; exit 2; }
[[ -z "$(docker ps -a --format '{{.Names}}' | grep -E '^gst-rc1-(real-l12|php-l12)-' || true)" ]] || { echo "RC1_REAL_L12=NO_GO_LAB_EXISTS"; exit 2; }
[[ -f "$RESTIC_REPOSITORY/config" && -f "$RESTIC_PASSWORD_FILE" ]] || { echo "RC1_REAL_L12=NO_GO_SNAPSHOT"; exit 2; }

snapshot=$(restic --no-lock snapshots --json | python3 -c '
import json,sys
daily=[x for x in json.load(sys.stdin) if "gstfleet-daily" in x.get("tags",[])]
assert daily
print(max(daily,key=lambda x:x["time"])["id"])')
container="gst-rc1-real-l12-$$"
diagnostics=""
cleanup() {
  [[ -z "$diagnostics" ]] || rm -f "$diagnostics"
  docker rm -f "$container" >/dev/null 2>&1 || true
  echo "RC1_REAL_L12_EPHEMERAL_CLEANUP=ATTEMPTED"
}
trap cleanup EXIT INT TERM HUP

docker run -d --rm --name "$container" --network none \
  --memory 1536m --memory-swap 1536m --cpus 1 --pids-limit 128 \
  --security-opt no-new-privileges --read-only \
  --tmpfs /var/lib/mysql:rw,nosuid,nodev,size=768m,mode=1777 \
  --tmpfs /var/run/mysqld:rw,nosuid,nodev,size=32m,mode=1777 \
  --tmpfs /tmp:rw,nosuid,nodev,size=64m,mode=1777 \
  -e MYSQL_ALLOW_EMPTY_PASSWORD=yes \
  "$mysql_image" --bind-address=127.0.0.1 --skip-name-resolve >/dev/null
net=$(docker inspect "$container" --format '{{.HostConfig.NetworkMode}}')
ports=$(docker inspect "$container" --format '{{json .HostConfig.PortBindings}}')
[[ "$net" == none && ( "$ports" == '{}' || "$ports" == null ) ]] || { echo "RC1_REAL_L12=NO_GO_NETWORK"; exit 2; }
echo "RC1_REAL_L12_DB_ISOLATION=PASS"
ready=0
for i in $(seq 1 100); do
  if docker logs "$container" 2>&1 | grep -F 'MySQL init process done. Ready for start up.' >/dev/null; then
    if docker exec "$container" mysqladmin --protocol=socket -uroot ping >/dev/null 2>&1; then ready=1; break; fi
  fi
  [[ "$(docker inspect "$container" --format '{{.State.Running}}' 2>/dev/null || true)" == true ]] || break
  sleep 1
done
[[ "$ready" == 1 ]] || { echo "RC1_REAL_L12=NO_GO_FINAL_MYSQL_START"; exit 2; }
echo "RC1_REAL_L12_FINAL_MYSQL_READY=PASS"

for pair in fleetbase:152 fleetbase_sandbox:138 fleetbase_storefront:33; do
  name=${pair%%:*}; count=${pair##*:}
  path=$(restic --no-lock ls "$snapshot" --json | python3 -c '
import json,sys
name=sys.argv[1]
hits=[]
for line in sys.stdin:
  try: x=json.loads(line)
  except ValueError:continue
  p=x.get("path","")
  if x.get("struct_type")=="node" and "/.gstfleet-daily-dump." in p and p.endswith("/"+name+".sql.gz"):hits.append(p)
assert len(hits)==1
print(hits[0])' "$name")
  docker exec "$container" mysql -uroot --protocol=socket -e "CREATE DATABASE \`$name\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" >/dev/null 2>&1
  diagnostics=$(mktemp /dev/shm/gst-rc1-l12-sql.XXXXXXXX)
  if ! restic --no-lock dump "$snapshot" "$path" | gzip -dc | docker exec -i "$container" mysql -uroot --protocol=socket "$name" >/dev/null 2>"$diagnostics"; then
    echo "RC1_REAL_L12_RESTORE_$name=NO_GO"
    code=$(grep -Eom 1 'ERROR [0-9]+' "$diagnostics" || true)
    echo "RC1_REAL_L12_MYSQL_CODE=${code:-UNCLASSIFIED}"
    exit 2
  fi
  rm -f "$diagnostics"; diagnostics=""
  restored=$(docker exec "$container" mysql -uroot --protocol=socket -N -B -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='$name' AND table_type='BASE TABLE';")
  [[ "$restored" == "$count" ]] || { echo "RC1_REAL_L12_RESTORE_$name=NO_GO_TABLES"; exit 2; }
  echo "RC1_REAL_L12_RESTORE_$name=PASS_$count"
done

# PHP shares the MySQL container's loopback-only network namespace.
# The application code is mounted read-only, and all storage/cache is tmpfs.
# No env credentials from production are mounted or passed.
php_cli() {
  local database="$1"; shift
  docker run --rm --network "container:$container" --memory 512m --memory-swap 512m --cpus 1 --pids-limit 96 \
    --read-only --security-opt no-new-privileges \
    --tmpfs /tmp:rw,nosuid,nodev,size=32m \
    --tmpfs /fleetbase/api/storage:rw,nosuid,nodev,size=64m \
    --tmpfs /fleetbase/api/bootstrap/cache:rw,nosuid,nodev,size=16m \
    --mount "type=bind,source=$api,target=/fleetbase/api,readonly" \
    -w /fleetbase/api --entrypoint php \
    -e APP_ENV=testing -e APP_URL=http://localhost.test \
    -e APP_KEY=base64:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA= \
    -e DB_CONNECTION=mysql -e DB_HOST=127.0.0.1 -e DB_PORT=3306 \
    -e DB_DATABASE="$database" -e DB_USERNAME=root -e DB_PASSWORD= \
    -e LOG_CHANNEL=stderr -e VIEW_COMPILED_PATH=/tmp \
    -e CACHE_DRIVER=array -e CACHE_STORE=array -e SESSION_DRIVER=array \
    -e QUEUE_CONNECTION=sync -e MAIL_MAILER=array -e TELESCOPE_ENABLED=false \
    "$php_image" "$@"
}

echo "RC1_REAL_L12_ARTISAN_STATUS_START"
diagnostics=$(mktemp /dev/shm/gst-rc1-l12-php.XXXXXXXX)
if ! php_cli fleetbase artisan migrate:status --no-ansi > /dev/null 2>"$diagnostics"; then
  echo "RC1_REAL_L12_ARTISAN_STATUS=NO_GO"
  err=$(grep -Eom 1 'SQLSTATE\[[A-Za-z0-9]+\]' "$diagnostics" || true)
  echo "RC1_REAL_L12_SQLSTATE=${err:-UNCLASSIFIED}"
  exit 2
fi
echo "RC1_REAL_L12_ARTISAN_STATUS=PASS"

echo "RC1_REAL_L12_PRIMARY_MIGRATION_START"
if ! php_cli fleetbase artisan migrate --force --no-interaction --no-ansi >/dev/null 2>"$diagnostics"; then
  echo "RC1_REAL_L12_PRIMARY_MIGRATION=NO_GO"
  err=$(grep -Eom 1 'SQLSTATE\[[A-Za-z0-9]+\]' "$diagnostics" || true)
  echo "RC1_REAL_L12_SQLSTATE=${err:-UNCLASSIFIED}"
  exit 2
fi
echo "RC1_REAL_L12_PRIMARY_MIGRATION=PASS"
if ! php_cli fleetbase artisan sandbox:migrate --force --no-interaction --no-ansi >/dev/null 2>"$diagnostics"; then
  echo "RC1_REAL_L12_SANDBOX_MIGRATION=NO_GO"
  err=$(grep -Eom 1 'SQLSTATE\[[A-Za-z0-9]+\]' "$diagnostics" || true)
  echo "RC1_REAL_L12_SQLSTATE=${err:-UNCLASSIFIED}"
  exit 2
fi
echo "RC1_REAL_L12_SANDBOX_MIGRATION=PASS"

for name in fleetbase fleetbase_sandbox fleetbase_storefront; do
  count=$(docker exec "$container" mysql -uroot --protocol=socket -N -B -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='$name' AND table_type='BASE TABLE';")
  echo "RC1_REAL_L12_POST_TABLES_$name=$count"
done
primary=$(docker exec "$container" mysql -uroot --protocol=socket -N -B -e "SELECT COUNT(*) FROM fleetbase.migrations;")
sandbox=$(docker exec "$container" mysql -uroot --protocol=socket -N -B -e "SELECT COUNT(*) FROM fleetbase_sandbox.migrations;")
echo "RC1_REAL_L12_PRIMARY_MIGRATIONS=$primary"
echo "RC1_REAL_L12_SANDBOX_MIGRATIONS=$sandbox"
[[ "$primary" -ge 394 && "$sandbox" -ge 304 ]] || { echo "RC1_REAL_L12_MIGRATION_REGISTRY=NO_GO"; exit 2; }
echo "RC1_REAL_L12_UPGRADE=PASS_ISOLATED"
echo "RC1_REAL_L12_COMPLETE_ROLLBACK=NOT_RUN"
echo "RC1_PRODUCTION=NO_GO"
