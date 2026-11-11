#!/usr/bin/env bash
# Fleetbase RC1: permanently failed Redis job -> disposable MySQL failed_jobs registry.
# NO production volumes, NO published ports, NO outbound network, NO customer data.
set -euo pipefail
umask 077
[[ "$(uname -s)" == Linux && "$(id -u)" -eq 0 ]] || { echo RC1_FAILED_JOB=NO_GO_CONTEXT; exit 2; }
for dep in docker awk grep mktemp; do command -v "$dep" >/dev/null || exit 2; done
available=$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)
(( available >= 5242880 )) || { echo RC1_FAILED_JOB=NO_GO_RAM; exit 2; }
redis_image=redis:7.4-alpine
mysql_image=mysql:8.0-oracle
php_image=fleetbase/fleetbase-api:v0.7.75
[[ "$(docker image inspect "$redis_image" --format '{{.Id}}')" == sha256:98c6ca8f397f86e469be752c3e7ed5eb8b17f2479840cb69a2e413037038e9f4 ]] || exit 2
[[ "$(docker image inspect "$mysql_image" --format '{{.Id}}')" == sha256:6cd09145362dfe6831b14545de3d5fd6cc75c37cfd6ef8561429c1fc73518b39 ]] || exit 2
[[ "$(docker image inspect "$php_image" --format '{{.Id}}')" == sha256:413e497080156b692e089106c37555a1e33edabda1bb0b6f09c104b7a2c6171a ]] || exit 2
[[ "$(docker inspect gstfleet-database-1 --format '{{.State.Running}} {{.State.Health.Status}}')" == "true healthy" ]] || exit 2
[[ -z "$(docker ps -a --format '{{.Names}}' | grep '^gst-rc1-failure-' || true)" ]] || exit 2

redis_name="gst-rc1-failure-redis-$$"
mysql_name="gst-rc1-failure-mysql-$$"
src=$(mktemp /dev/shm/gst-rc1-failure.XXXXXXXX.php)
cleanup() {
  rm -f "$src"
  docker rm -f "$mysql_name" >/dev/null 2>&1 || true
  docker rm -f "$redis_name" >/dev/null 2>&1 || true
  echo RC1_FAILED_JOB_LAB_CLEANUP=ATTEMPTED
}
trap cleanup EXIT INT TERM HUP
cat > "$src" <<'PHP'
<?php
require 'vendor/autoload.php';
$app = require 'bootstrap/app.php';
$app->make(Illuminate\Contracts\Console\Kernel::class)->bootstrap();
$job = Illuminate\Queue\CallQueuedClosure::create(function () {
    throw new \RuntimeException('rc1-intentional-permanent-failure-no-customer-data');
});
Illuminate\Support\Facades\Queue::connection('redis')->push($job);
echo "RC1_JOB_DISPATCHED=PASS\n";
PHP
chmod 400 "$src"

docker run --rm -d --name "$redis_name" --network none \
  --memory 128m --memory-swap 128m --pids-limit 64 --read-only \
  --security-opt no-new-privileges --tmpfs /tmp:rw,nosuid,nodev,size=8m \
  --entrypoint redis-server "$redis_image" --bind 127.0.0.1 \
  --protected-mode yes --save '' --appendonly no >/dev/null
[[ "$(docker inspect "$redis_name" --format '{{.HostConfig.NetworkMode}} {{json .HostConfig.PortBindings}}')" == 'none {}' ]] || exit 2
for i in $(seq 1 20); do
  if docker exec "$redis_name" redis-cli ping 2>/dev/null | grep -qx PONG; then break; fi
  sleep 1
done
docker exec "$redis_name" redis-cli ping | grep -qx PONG

docker run --rm -d --name "$mysql_name" --network "container:$redis_name" \
  --memory 1024m --memory-swap 1024m --pids-limit 128 --read-only \
  --security-opt no-new-privileges \
  --tmpfs /var/lib/mysql:rw,nosuid,nodev,size=512m,mode=1777 \
  --tmpfs /var/run/mysqld:rw,nosuid,nodev,size=32m,mode=1777 \
  --tmpfs /tmp:rw,nosuid,nodev,size=32m,mode=1777 \
  -e MYSQL_ALLOW_EMPTY_PASSWORD=yes "$mysql_image" --bind-address=127.0.0.1 --skip-name-resolve >/dev/null
ready=0
for i in $(seq 1 90); do
  if docker logs "$mysql_name" 2>&1 | grep -F 'MySQL init process done. Ready for start up.' >/dev/null &&
    docker exec "$mysql_name" mysqladmin -uroot --protocol=socket ping >/dev/null 2>&1; then ready=1; break; fi
  sleep 1
done
[[ "$ready" == 1 ]] || { echo RC1_FAILED_JOB_MYSQL=NO_GO; exit 2; }
echo RC1_FAILED_JOB_EPHEMERAL_MYSQL=PASS

docker exec "$mysql_name" mysql -uroot --protocol=socket -e "
CREATE DATABASE fleetbase;
USE fleetbase;
CREATE TABLE failed_jobs (
 id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
 uuid VARCHAR(255) NOT NULL UNIQUE,
 connection TEXT NOT NULL,
 queue TEXT NOT NULL,
 payload LONGTEXT NOT NULL,
 exception LONGTEXT NOT NULL,
 failed_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);
" >/dev/null
echo RC1_FAILED_JOB_TEST_TABLE=PASS

php_lab() {
  local api="$1"; shift
  docker run --rm --network "container:$redis_name" --memory 384m --memory-swap 384m \
    --pids-limit 96 --read-only --security-opt no-new-privileges \
    --tmpfs /tmp:rw,nosuid,nodev,size=16m \
    --tmpfs /fleetbase/api/storage:rw,nosuid,nodev,size=32m \
    --tmpfs /fleetbase/api/bootstrap/cache:rw,nosuid,nodev,size=16m \
    --mount "type=bind,source=$api,target=/fleetbase/api,readonly" \
    --mount "type=bind,source=$src,target=/tmp/rc1-job.php,readonly" \
    -w /fleetbase/api --entrypoint php \
    -e APP_ENV=testing -e APP_URL=http://localhost.test \
    -e APP_KEY=base64:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA= \
    -e REDIS_HOST=127.0.0.1 -e REDIS_PORT=6379 -e QUEUE_CONNECTION=redis \
    -e CACHE_DRIVER=array -e CACHE_STORE=array -e SESSION_DRIVER=array \
    -e LOG_CHANNEL=stderr -e VIEW_COMPILED_PATH=/tmp -e MAIL_MAILER=array \
    -e DB_CONNECTION=mysql -e DB_HOST=127.0.0.1 -e DB_PORT=3306 \
    -e DB_DATABASE=fleetbase -e DB_USERNAME=root -e DB_PASSWORD= \
    -e QUEUE_FAILED_DRIVER=database-uuids \
    "$php_image" "$@"
}

for phase in L12 L10; do
  if [[ "$phase" == L12 ]]; then api=/root/.gst-rc1-runtime-31a6a026/repo/api; else api=/root/.gst-rc1-legacy-67b2db64/repo/api; fi
  [[ -f "$api/vendor/autoload.php" ]] || { echo RC1_FAILED_JOB_VENDOR=NO_GO; exit 2; }
  docker exec "$redis_name" redis-cli FLUSHDB >/dev/null
  docker exec "$mysql_name" mysql -uroot --protocol=socket -e "TRUNCATE TABLE fleetbase.failed_jobs;" >/dev/null
  php_lab "$api" /tmp/rc1-job.php 2>/dev/null | grep -qx 'RC1_JOB_DISPATCHED=PASS'
  queue_key=$(docker exec "$redis_name" redis-cli --scan --pattern '*queues:default' | head -n 1)
  [[ -n "$queue_key" && "$(docker exec "$redis_name" redis-cli LLEN "$queue_key")" == 1 ]] || {
    echo "RC1_${phase}_PERMANENT_FAIL=NO_GO_ENQUEUE"; exit 2;
  }
  echo "RC1_${phase}_FAILED_JOB_ENQUEUE=PASS"
  # A permanent failure may still result in process exit zero; validate DB, not exit.
  php_lab "$api" artisan queue:work redis --once --tries=1 --backoff=0 --timeout=12 --no-ansi >/dev/null 2>/dev/null || true
  failed_count=$(docker exec "$mysql_name" mysql -uroot --protocol=socket -N -B -e "SELECT COUNT(*) FROM fleetbase.failed_jobs;")
  pending=$(docker exec "$redis_name" redis-cli LLEN "$queue_key")
  echo "RC1_${phase}_FAILED_JOB_TABLE_COUNT=$failed_count"
  echo "RC1_${phase}_FAILED_JOB_QUEUE_REMAINING=$pending"
  [[ "$failed_count" == 1 && "$pending" == 0 ]] || { echo "RC1_${phase}_FAILED_JOB_PERSISTENCE=NO_GO"; exit 2; }
  echo "RC1_${phase}_FAILED_JOB_PERSISTENCE=PASS"
done
echo RC1_FAILED_JOBS_L12_L10=PASS_EPHEMERAL
echo RC1_PRODUCTION=NO_GO
