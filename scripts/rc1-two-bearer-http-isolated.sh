#!/usr/bin/env bash
set -euo pipefail
umask 077
[[ "$(uname -s)" == Linux && "$(id -u)" -eq 0 ]] || exit 2
export RESTIC_REPOSITORY=/root/gstfleet-secure-repository RESTIC_PASSWORD_FILE=/root/gstfleet-secure-repository.password
[[ -f /dev/shm/gst-rc1-core-fail-closed-candidate.php && -f /dev/shm/gst-rc1-auth-session-candidate.php ]] || exit 2
[[ "$(docker inspect gstfleet-database-1 --format '{{.State.Running}} {{.State.Health.Status}}')" == 'true healthy' ]] || exit 2
(( $(awk '/MemAvailable:/ {print $2}' /proc/meminfo) > 5242880 )) || { echo RC1_REAL_TWO_BEARER_HTTP=NO_GO_MEMORY_BELOW_5_GIB; exit 2; }
[[ "$(docker image inspect mysql:8.0-oracle --format '{{.Id}}')" == sha256:6cd09145362dfe6831b14545de3d5fd6cc75c37cfd6ef8561429c1fc73518b39 ]] || exit 2
[[ "$(docker image inspect fleetbase/fleetbase-api:v0.7.75 --format '{{.Id}}')" == sha256:413e497080156b692e089106c37555a1e33edabda1bb0b6f09c104b7a2c6171a ]] || exit 2
name="gst-rc1-http-auth-db-$$"
web="gst-rc1-http-auth-web-$$"
trap 'docker rm -f "$web" "$name" >/dev/null 2>&1 || true; echo RC1_AUTH_HTTP_CLEANUP=ATTEMPTED' EXIT
docker run --rm -d --name "$name" --network none --memory 1536m --memory-swap 1536m --cpus 1 --pids-limit 128 --read-only --tmpfs /var/lib/mysql:rw,nosuid,nodev,size=768m,mode=1777 --tmpfs /var/run/mysqld:rw,nosuid,nodev,size=32m,mode=1777 --tmpfs /tmp:rw,nosuid,nodev,size=64m,mode=1777 -e MYSQL_ALLOW_EMPTY_PASSWORD=yes mysql:8.0-oracle --bind-address=127.0.0.1 --skip-name-resolve >/dev/null
[[ "$(docker inspect "$name" --format '{{.HostConfig.NetworkMode}} {{json .HostConfig.PortBindings}}')" == 'none {}' ]] || exit 2
ready=0
for i in $(seq 1 100); do
 if docker logs "$name" 2>&1 | grep -F 'MySQL init process done. Ready for start up.' >/dev/null && docker exec "$name" mysqladmin -uroot --protocol=socket ping >/dev/null 2>&1; then ready=1;break;fi
 sleep 1
done
[[ "$ready" == 1 ]] || { echo RC1_AUTH_DB=NO_GO_READY;exit 2; }
echo RC1_AUTH_DB_EPHEMERAL=PASS
snap=$(restic --no-lock snapshots --json | python3 -c 'import json,sys;s=[x for x in json.load(sys.stdin) if "gstfleet-daily" in x.get("tags",[])];assert s;print(max(s,key=lambda x:x["time"])["id"])')
path=$(restic --no-lock ls "$snap" --json | python3 -c 'import json,sys;f=[x.get("path","") for l in sys.stdin if l.strip() for x in [json.loads(l)] if x.get("struct_type")=="node" and "/.gstfleet-daily-dump." in x.get("path","") and x.get("path","").endswith("/fleetbase.sql.gz")];assert len(f)==1;print(f[0])')
docker exec "$name" mysql -uroot --protocol=socket -e 'CREATE DATABASE fleetbase' >/dev/null
if ! restic --no-lock dump "$snap" "$path" | gzip -dc | docker exec -i "$name" mysql -uroot --protocol=socket --init-command='SET FOREIGN_KEY_CHECKS=0' fleetbase >/dev/null 2>/dev/null; then echo RC1_AUTH_RESTORE=NO_GO;exit 2;fi
[[ "$(docker exec "$name" mysql -uroot --protocol=socket -N -B -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='fleetbase' AND table_type='BASE TABLE'")" == 152 ]] || exit 2
echo RC1_AUTH_RESTORED_152=PASS
docker exec -i "$name" mysql -uroot --protocol=socket fleetbase >/dev/null <<'SQL'
-- Synthetic users and their companies form an FK cycle; populate both in
-- disposable MySQL, then restore FK enforcement before running HTTP probes.
SET FOREIGN_KEY_CHECKS=0;
INSERT INTO users(uuid,public_id,company_uuid,username,name,type,status) VALUES
('ca111111-1111-4111-8111-111111111111','rc1-auth-user-a','aa111111-1111-4111-8111-111111111111','rc1-auth-user-a','RC1 Test A','user','active'),
('cb222222-2222-4222-8222-222222222222','rc1-auth-user-b','bb222222-2222-4222-8222-222222222222','rc1-auth-user-b','RC1 Test B','user','active');
INSERT INTO companies(uuid,public_id,owner_uuid,name,status) VALUES
('aa111111-1111-4111-8111-111111111111','rc1-company-a','ca111111-1111-4111-8111-111111111111','RC1 A','active'),
('bb222222-2222-4222-8222-222222222222','rc1-company-b','cb222222-2222-4222-8222-222222222222','RC1 B','active');
INSERT INTO api_credentials(uuid,user_uuid,company_uuid,name,`key`,api) VALUES
('da111111-1111-4111-8111-111111111111','ca111111-1111-4111-8111-111111111111','aa111111-1111-4111-8111-111111111111','RC1 A','flb_live_rc1_auth_a_20261110','core'),
('db222222-2222-4222-8222-222222222222','cb222222-2222-4222-8222-222222222222','bb222222-2222-4222-8222-222222222222','RC1 B','flb_live_rc1_auth_b_20261110','core');
INSERT INTO orders(uuid,public_id,company_uuid,created_by_uuid,status) VALUES
('ea111111-1111-4111-8111-111111111111','rc1-test-order-a','aa111111-1111-4111-8111-111111111111','ca111111-1111-4111-8111-111111111111','created'),
('eb222222-2222-4222-8222-222222222222','rc1-test-order-b','bb222222-2222-4222-8222-222222222222','cb222222-2222-4222-8222-222222222222','created');
SET FOREIGN_KEY_CHECKS=1;
SQL
echo RC1_AUTH_FIXTURES=PASS
app=/root/.gst-rc1-runtime-31a6a026/repo/api
docker run --rm -d --name "$web" --network "container:$name" --memory 512m --memory-swap 512m --cpus 1 --pids-limit 96 --read-only --tmpfs /tmp:rw,nosuid,nodev,size=32m --tmpfs /fleetbase/api/storage:rw,nosuid,nodev,size=64m --tmpfs /fleetbase/api/bootstrap/cache:rw,nosuid,nodev,size=16m --mount "type=bind,source=$app,target=/fleetbase/api,readonly" --mount 'type=bind,source=/dev/shm/gst-rc1-core-fail-closed-candidate.php,target=/fleetbase/api/vendor/fleetbase/core-api/src/Traits/HasApiModelBehavior.php,readonly' --mount 'type=bind,source=/dev/shm/gst-rc1-auth-session-candidate.php,target=/fleetbase/api/vendor/fleetbase/core-api/src/Support/Auth.php,readonly' -w /fleetbase/api --entrypoint php -e APP_ENV=testing -e APP_DEBUG=false -e APP_KEY=base64:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA= -e DB_CONNECTION=mysql -e DB_HOST=127.0.0.1 -e DB_DATABASE=fleetbase -e DB_USERNAME=root -e DB_PASSWORD= -e CACHE_DRIVER=array -e CACHE_STORE=array -e SESSION_DRIVER=array -e LOG_CHANNEL=stderr -e VIEW_COMPILED_PATH=/tmp -e QUEUE_CONNECTION=sync -e MAIL_MAILER=array fleetbase/fleetbase-api:v0.7.75 -S 127.0.0.1:18770 -t public public/index.php >/dev/null
for i in $(seq 1 20); do h=$(docker exec "$web" curl -s -o /dev/null -w '%{http_code}' --max-time 2 http://127.0.0.1:18770/health 2>/dev/null || true);[[ "$h" == 200 ]] && break;sleep 1;done
[[ "$h" == 200 ]] || exit 2
echo RC1_AUTH_HEALTH=PASS
status(){ local t="$1" p="$2";if [[ -z "$t" ]]; then docker exec "$web" curl -s -o /dev/null -w '%{http_code}' -H 'Accept: application/json' --max-time 12 "http://127.0.0.1:18770/$p";else docker exec "$web" curl -s -o /dev/null -w '%{http_code}' -H 'Accept: application/json' -H "Authorization: Bearer $t" --max-time 12 "http://127.0.0.1:18770/$p";fi; }
a=$(status '' 'v1/orders/rc1-test-order-a')
echo "RC1_ANONYMOUS_STATUS=$a"
[[ "$a" == 401 ]] || exit 2
for side in a b; do
 if [[ "$side" == a ]];then token=flb_live_rc1_auth_a_20261110;own=rc1-test-order-a;foreign=rc1-test-order-b;else token=flb_live_rc1_auth_b_20261110;own=rc1-test-order-b;foreign=rc1-test-order-a;fi
 org=$(status "$token" 'v1/organizations/current')
 ok=$(status "$token" "v1/orders/$own")
 deny=$(status "$token" "v1/orders/$foreign")
 echo "RC1_SIDE_$side ORG=$org OWN=$ok FOREIGN=$deny"
 [[ "$ok" == 200 && "$deny" == 404 ]] || { echo "RC1_SIDE_$side=NO_GO_ORDER_IDOR";exit 2; }
 if [[ "$org" != 200 ]]; then
   echo "RC1_SIDE_$side=PASS_ORDER_IDOR_ORG_ROUTE_NEEDS_DIAGNOSIS"
 else
   echo "RC1_SIDE_$side=PASS_ORDER_IDOR_AND_ORG"
 fi
done
echo RC1_REAL_TWO_BEARER_HTTP_ORDER_IDOR=PASS
echo RC1_ORGANIZATION_CURRENT_ROUTE=NEEDS_SEPARATE_FIXTURE_DIAGNOSIS
echo RC1_PRODUCTION=NO_GO
