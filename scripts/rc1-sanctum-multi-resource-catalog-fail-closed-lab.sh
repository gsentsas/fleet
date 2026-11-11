#!/usr/bin/env bash
set -euo pipefail
umask 077
[[ "$(uname -s)" == Linux && "$(id -u)" -eq 0 ]] || exit 2
export RESTIC_REPOSITORY=/root/gstfleet-secure-repository RESTIC_PASSWORD_FILE=/root/gstfleet-secure-repository.password
[[ -f /dev/shm/gst-rc1-core-fail-closed-candidate.php && -f /dev/shm/gst-rc1-auth-session-candidate.php ]] || exit 2
[[ -f /dev/shm/gst-rc1-authorization-guard-candidate.php ]] || exit 2
[[ "$(docker inspect gstfleet-database-1 --format '{{.State.Running}} {{.State.Health.Status}}')" == 'true healthy' ]] || exit 2
(( $(awk '/MemAvailable:/ {print $2}' /proc/meminfo) > 5242880 )) || { echo RC1_REAL_TWO_BEARER_HTTP=NO_GO_MEMORY_BELOW_5_GIB; exit 2; }
[[ "$(docker image inspect mysql:8.0-oracle --format '{{.Id}}')" == sha256:6cd09145362dfe6831b14545de3d5fd6cc75c37cfd6ef8561429c1fc73518b39 ]] || exit 2
[[ "$(docker image inspect fleetbase/fleetbase-api:v0.7.75 --format '{{.Id}}')" == sha256:413e497080156b692e089106c37555a1e33edabda1bb0b6f09c104b7a2c6171a ]] || exit 2
[[ "$(docker image inspect redis:7.4-alpine --format '{{.Id}}')" == sha256:98c6ca8f397f86e469be752c3e7ed5eb8b17f2479840cb69a2e413037038e9f4 ]] || exit 2
name="gst-rc1-http-auth-db-$$"
web="gst-rc1-http-auth-web-$$"
redis="gst-rc1-http-auth-redis-$$"
trap 'docker rm -f "$web" "$redis" "$name" >/dev/null 2>&1 || true; echo RC1_AUTH_HTTP_CLEANUP=ATTEMPTED' EXIT
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
# Synthetic Sanctum credentials only in the disposable MySQL database.
# A = non-admin with no explicit role; B = synthetic admin control profile.
docker exec -i "$name" mysql -uroot --protocol=socket fleetbase >/dev/null <<'SQL'
UPDATE users SET type='admin' WHERE public_id='rc1-auth-user-b';
-- Company memberships are mandatory for proxying IAM permission methods.
-- No role/permission attached to company A's membership.
INSERT INTO company_users(uuid,company_uuid,user_uuid,status,created_at,updated_at) VALUES
('fa111111-1111-4111-8111-111111111111','aa111111-1111-4111-8111-111111111111','ca111111-1111-4111-8111-111111111111','active',NOW(),NOW()),
('fb222222-2222-4222-8222-222222222222','bb222222-2222-4222-8222-222222222222','cb222222-2222-4222-8222-222222222222','active',NOW(),NOW());
INSERT INTO personal_access_tokens(tokenable_type,tokenable_id,name,token,abilities,created_at,updated_at)
SELECT CONCAT('Fleetbase',CHAR(92),'Models',CHAR(92),'User'),uuid,
 'rc1-no-role',SHA2('rc1_sanctum_no_role_20261110',256),'["*"]',NOW(),NOW()
FROM users WHERE public_id='rc1-auth-user-a';
INSERT INTO personal_access_tokens(tokenable_type,tokenable_id,name,token,abilities,created_at,updated_at)
SELECT CONCAT('Fleetbase',CHAR(92),'Models',CHAR(92),'User'),uuid,
 'rc1-admin',SHA2('rc1_sanctum_admin_20261110',256),'["*"]',NOW(),NOW()
FROM users WHERE public_id='rc1-auth-user-b';
SQL
echo RC1_SANCTUM_SYNTHETIC_FIXTURES=PASS

docker exec -i "$name" mysql -uroot --protocol=socket fleetbase >/dev/null <<'SQL'
INSERT INTO users(uuid,public_id,company_uuid,username,name,type,status) VALUES
('cc333333-3333-4333-8333-333333333333','rc1-reader','aa111111-1111-4111-8111-111111111111','rc1-reader','RC1 Reader','user','active'),
('cd444444-4444-4444-8444-444444444444','rc1-editor','aa111111-1111-4111-8111-111111111111','rc1-editor','RC1 Editor','user','active');
INSERT INTO company_users(uuid,company_uuid,user_uuid,status,created_at,updated_at) VALUES
('fc333333-3333-4333-8333-333333333333','aa111111-1111-4111-8111-111111111111','cc333333-3333-4333-8333-333333333333','active',NOW(),NOW()),
('fd444444-4444-4444-8444-444444444444','aa111111-1111-4111-8111-111111111111','cd444444-4444-4444-8444-444444444444','active',NOW(),NOW());
SQL
echo RC1_IAM_EXTRA_PROFILES=PASS


# Setting/branding and other Fleetbase resource paths call Redis directly.
# Keep Redis local to the same networkless temporary MySQL namespace.
docker run -d --rm --name "$redis" --network "container:$name" --memory 128m --memory-swap 128m --pids-limit 64 --read-only --security-opt no-new-privileges --tmpfs /tmp:rw,nosuid,nodev,size=8m --entrypoint redis-server redis:7.4-alpine --bind 127.0.0.1 --protected-mode yes --save '' --appendonly no >/dev/null
for i in $(seq 1 15); do
 if docker exec "$redis" redis-cli -h 127.0.0.1 ping 2>/dev/null | grep -qx PONG; then break; fi
 sleep 1
done
docker exec "$redis" redis-cli -h 127.0.0.1 ping | grep -qx PONG || { echo RC1_AUTH_REDIS=NO_GO; exit 2; }
echo RC1_AUTH_REDIS_EPHEMERAL=PASS
app=/root/.gst-rc1-runtime-31a6a026/repo/api
docker run --rm -d --name "$web" --network "container:$name" --memory 512m --memory-swap 512m --cpus 1 --pids-limit 96 --read-only --tmpfs /tmp:rw,nosuid,nodev,size=32m --tmpfs /fleetbase/api/storage:rw,nosuid,nodev,size=64m --tmpfs /fleetbase/api/bootstrap/cache:rw,nosuid,nodev,size=16m --mount "type=bind,source=$app,target=/fleetbase/api,readonly" --mount 'type=bind,source=/dev/shm/gst-rc1-core-fail-closed-candidate.php,target=/fleetbase/api/vendor/fleetbase/core-api/src/Traits/HasApiModelBehavior.php,readonly' --mount 'type=bind,source=/dev/shm/gst-rc1-auth-session-candidate.php,target=/fleetbase/api/vendor/fleetbase/core-api/src/Support/Auth.php,readonly' --mount 'type=bind,source=/dev/shm/gst-rc1-authorization-guard-candidate.php,target=/fleetbase/api/vendor/fleetbase/core-api/src/Http/Middleware/AuthorizationGuard.php,readonly' -w /fleetbase/api --entrypoint php -e APP_ENV=testing -e APP_DEBUG=false -e APP_KEY=base64:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA= -e DB_CONNECTION=mysql -e DB_HOST=127.0.0.1 -e DB_DATABASE=fleetbase -e DB_USERNAME=root -e DB_PASSWORD= -e REDIS_HOST=127.0.0.1 -e REDIS_PORT=6379 -e REDIS_PASSWORD= -e CACHE_DRIVER=array -e CACHE_STORE=array -e SESSION_DRIVER=array -e LOG_CHANNEL=stderr -e VIEW_COMPILED_PATH=/tmp -e QUEUE_CONNECTION=sync -e MAIL_MAILER=array fleetbase/fleetbase-api:v0.7.75 -S 127.0.0.1:18770 -t public public/index.php >/dev/null
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
 if [[ "$deny" == 500 || "$org" == 500 ]]; then
   # Only exception *types* and PHP source path names, never messages,
   # tokens, response bodies, SQL values, or restored business records.
   classes=$(docker logs "$web" 2>&1 | grep -Eo '[A-Za-z_\\\\]+(Exception|Error)' | sort -u | head -n 8 | tr '\n' ',' || true)
   echo "RC1_SIDE_$side"_ERROR_TYPES="$classes"
 fi
 [[ "$ok" == 200 && "$deny" == 404 ]] || { echo "RC1_SIDE_$side=NO_GO_ORDER_IDOR";exit 2; }
 if [[ "$org" != 200 ]]; then
   echo "RC1_SIDE_$side=PASS_ORDER_IDOR_ORG_ROUTE_NEEDS_DIAGNOSIS"
 else
   echo "RC1_SIDE_$side=PASS_ORDER_IDOR_AND_ORG"
 fi
done
# Mint actual Sanctum tokens via Fleetbase User::createToken(), not hand-built
# SQL token rows. Capture in shell variables, never print or persist.
mint_sanctum(){
 local account="$1"
 docker exec "$web" php -r '
 require "vendor/autoload.php";
 $app=require "bootstrap/app.php";
 $app->make(Illuminate\Contracts\Console\Kernel::class)->bootstrap();
 $user=Fleetbase\Models\User::where("public_id",$argv[1])->firstOrFail();
 $new=$user->createToken("rc1-sanctum-real-mint",["*"]);
 echo $new->plainTextToken;
 ' "$account" 2>/dev/null
}
no_role_minted=$(mint_sanctum rc1-auth-user-a) || { echo RC1_SANCTUM_REAL_MINT=NO_GO_A;exit 2; }
admin_minted=$(mint_sanctum rc1-auth-user-b) || { echo RC1_SANCTUM_REAL_MINT=NO_GO_B;exit 2; }
[[ "$no_role_minted" == *"|"* && "$admin_minted" == *"|"* ]] || { echo RC1_SANCTUM_REAL_MINT=NO_GO_FORMAT; exit 2; }
echo RC1_SANCTUM_REAL_CREATE_TOKEN=PASS

grant_iam(){
 docker exec "$web" php -r '
 require "vendor/autoload.php";
 $app=require "bootstrap/app.php";
 $app->make(Illuminate\Contracts\Console\Kernel::class)->bootstrap();
 $names=["fleet-ops list order","fleet-ops view order","fleet-ops update order"];
 foreach($names as $n){if(!Fleetbase\Models\Permission::where("name",$n)->exists()){echo "RC1_PERMISSION_MISSING=".$n.PHP_EOL;exit(2);}}
 $reader=Fleetbase\Models\CompanyUser::where("uuid","fc333333-3333-4333-8333-333333333333")->firstOrFail();
 $editor=Fleetbase\Models\CompanyUser::where("uuid","fd444444-4444-4444-8444-444444444444")->firstOrFail();
 $reader->givePermissionTo(["fleet-ops list order","fleet-ops view order"]);
 $editor->givePermissionTo(["fleet-ops list order","fleet-ops view order","fleet-ops update order"]);
 echo "RC1_IAM_GRANTS=PASS".PHP_EOL;
 ' 2>/dev/null
}
grant_iam || { echo RC1_IAM_GRANTS=NO_GO;exit 2; }
reader_minted=$(mint_sanctum rc1-reader) || exit 2
editor_minted=$(mint_sanctum rc1-editor) || exit 2
[[ "$reader_minted" == *"|"* && "$editor_minted" == *"|"* ]] || exit 2
echo RC1_IAM_READER_EDITOR_TOKENS=PASS

classify_401(){
 local token="$1" uri="$2" response
 response=$(docker exec "$web" curl -s --max-time 15 -H 'Accept: application/json' -H "Authorization: Bearer $token" "http://127.0.0.1:18770/$uri" 2>/dev/null || true)
 if [[ "$response" == *"User is not authorized to "* ]];then
  echo PERMISSION_DENIED
 elif [[ "$response" == *"Unauthenticated"* ]];then
  echo UNAUTHENTICATED
 else
  echo OTHER
 fi
}
# Internal API runs through a separate Sanctum and AuthorizationGuard flow.
# This is a diagnostic: report exact HTTP codes without assuming a role gate.
for profile in no_role admin; do
 if [[ "$profile" == no_role ]]; then t="$no_role_minted"; else t="$admin_minted"; fi
 for uri in int/v1/orders int/v1/orders/rc1-test-order-a; do
  status_code=$(status "$t" "$uri")
  case "$uri" in
    int/v1/orders) label=LIST;;
    *) label=DETAIL;;
  esac
  echo "RC1_SANCTUM_${profile}_${label}_HTTP=$status_code"
  if [[ "$status_code" == 401 ]]; then
    echo "RC1_SANCTUM_${profile}_${label}_401_CLASS=$(classify_401 "$t" "$uri")"
  fi
  if [[ "$status_code" == 500 ]]; then
    # Only exception classes; never logs, error messages, tokens or PII.
    exception_classes=$(docker logs "$web" 2>&1 | grep -Eo '[A-Za-z_\\\\]+(Exception|Error)' | sort -u | head -n 10 | tr '\n' ',' || true)
    echo "RC1_SANCTUM_${profile}_${label}_EXCEPTION_TYPES=$exception_classes"
  fi
  [[ "$status_code" =~ ^[0-9]{3}$ ]] || { echo RC1_SANCTUM_HTTP=NO_GO_TRANSPORT; exit 2; }
 done
done
# Assert the observed role decisions, including writes and SQL side effects.
admin_own=$(status "$admin_minted" 'int/v1/orders/rc1-test-order-b')
admin_foreign=$(status "$admin_minted" 'int/v1/orders/rc1-test-order-a')
no_role_own=$(status "$no_role_minted" 'int/v1/orders/rc1-test-order-a')
echo "RC1_SANCTUM_ADMIN_OWN_DETAIL_HTTP=$admin_own"
echo "RC1_SANCTUM_ADMIN_FOREIGN_DETAIL_HTTP=$admin_foreign"
echo "RC1_SANCTUM_NO_ROLE_OWN_DETAIL_HTTP=$no_role_own"
no_role_put=$(docker exec "$web" curl -s -o /dev/null -w '%{http_code}' --max-time 15 --request PUT -H 'Accept: application/json' -H 'Content-Type: application/json' -H "Authorization: Bearer $no_role_minted" --data '{"notes":"rc1-forbidden"}' 'http://127.0.0.1:18770/int/v1/orders/rc1-test-order-a' || echo ERROR)
no_role_delete=$(docker exec "$web" curl -s -o /dev/null -w '%{http_code}' --max-time 15 --request DELETE -H 'Accept: application/json' -H "Authorization: Bearer $no_role_minted" 'http://127.0.0.1:18770/int/v1/orders/rc1-test-order-a' || echo ERROR)
echo "RC1_SANCTUM_NO_ROLE_OWN_PUT_HTTP=$no_role_put"
echo "RC1_SANCTUM_NO_ROLE_OWN_DELETE_HTTP=$no_role_delete"
unchanged=$(docker exec "$name" mysql -uroot --protocol=socket -N -B -e "SELECT COUNT(*) FROM fleetbase.orders WHERE public_id IN ('rc1-test-order-a','rc1-test-order-b') AND notes IS NULL AND deleted_at IS NULL AND status='created';")
[[ "$unchanged" == 2 ]] || { echo RC1_SANCTUM_NO_ROLE_MUTATIONS=NO_GO_SQL;exit 2; }
echo RC1_SANCTUM_NO_ROLE_MUTATIONS=PASS_SQL_UNCHANGED
[[ "$admin_own" == 200 && "$admin_foreign" == 404 && "$no_role_own" == 401 && "$no_role_put" == 401 && "$no_role_delete" == 401 ]] || { echo RC1_SANCTUM_ROLE_MATRIX=NO_GO_CODES;exit 2; }
echo RC1_SANCTUM_ADMIN_NO_ROLE_HTTP_MATRIX=PASS

for profile in reader editor;do
 if [[ "$profile" == reader ]];then t="$reader_minted";else t="$editor_minted";fi
 list_code=$(status "$t" 'int/v1/orders')
 own_code=$(status "$t" 'int/v1/orders/rc1-test-order-a')
 foreign_code=$(status "$t" 'int/v1/orders/rc1-test-order-b')
 echo "RC1_IAM_$profile LIST=$list_code OWN=$own_code FOREIGN=$foreign_code"
 [[ "$list_code" == 200 && "$own_code" == 200 && "$foreign_code" == 404 ]] || { echo "RC1_IAM_$profile=NO_GO_READ";exit 2; }
done
reader_put=$(docker exec "$web" curl -s -o /dev/null -w '%{http_code}' --max-time 15 -X PUT -H 'Accept: application/json' -H 'Content-Type: application/json' -H "Authorization: Bearer $reader_minted" --data '{"notes":"rc1-forbidden"}' 'http://127.0.0.1:18770/int/v1/orders/rc1-test-order-a')
reader_delete=$(docker exec "$web" curl -s -o /dev/null -w '%{http_code}' --max-time 15 -X DELETE -H 'Accept: application/json' -H "Authorization: Bearer $reader_minted" 'http://127.0.0.1:18770/int/v1/orders/rc1-test-order-a')
editor_delete=$(docker exec "$web" curl -s -o /dev/null -w '%{http_code}' --max-time 15 -X DELETE -H 'Accept: application/json' -H "Authorization: Bearer $editor_minted" 'http://127.0.0.1:18770/int/v1/orders/rc1-test-order-a')
echo "RC1_IAM_READER_PUT=$reader_put READER_DELETE=$reader_delete EDITOR_DELETE=$editor_delete"
[[ "$reader_put" == 401 && "$reader_delete" == 401 && "$editor_delete" == 401 ]] || { echo RC1_IAM_WRITE_DENIAL=NO_GO;exit 2; }
unchanged=$(docker exec "$name" mysql -uroot --protocol=socket -N -B -e "SELECT COUNT(*) FROM fleetbase.orders WHERE public_id IN ('rc1-test-order-a','rc1-test-order-b') AND notes IS NULL AND deleted_at IS NULL;")
[[ "$unchanged" == 2 ]] || { echo RC1_IAM_SQL_BEFORE=NO_GO;exit 2; }
editor_put=$(docker exec "$web" curl -s -o /dev/null -w '%{http_code}' --max-time 15 -X PUT -H 'Accept: application/json' -H 'Content-Type: application/json' -H "Authorization: Bearer $editor_minted" --data '{"notes":"rc1-editor-authorized"}' 'http://127.0.0.1:18770/int/v1/orders/rc1-test-order-a')
echo "RC1_IAM_EDITOR_PUT=$editor_put"
[[ "$editor_put" == 200 ]] || { echo RC1_IAM_EDITOR_PUT=NO_GO;exit 2; }
updated=$(docker exec "$name" mysql -uroot --protocol=socket -N -B -e "SELECT COUNT(*) FROM fleetbase.orders WHERE public_id='rc1-test-order-a' AND notes='rc1-editor-authorized' AND deleted_at IS NULL;")
[[ "$updated" == 1 ]] || { echo RC1_IAM_EDITOR_SQL=NO_GO;exit 2; }
echo RC1_SANCTUM_FOUR_PROFILE_IAM=PASS

# Negative proof: when the "view order" catalog record is absent, the guard
# must still reject a no-role user. We remove only a synthetic test catalog
# entry in the ephemeral restored DB, after the four-profile baseline passes.
# Rename the three exact/wildcard permission names, preserving FK records
# and directive references. Only the disposable restored catalog is touched.
before_count=$(docker exec "$name" mysql -uroot --protocol=socket -N -B -e "SELECT COUNT(*) FROM fleetbase.permissions WHERE name IN ('fleet-ops view order','fleet-ops * order','fleet-ops *');")
[[ "$before_count" == 3 ]] || { echo RC1_MISSING_PERMISSION_PREFLIGHT=NO_GO;exit 2;}
docker exec "$name" mysql -uroot --protocol=socket -e "UPDATE fleetbase.permissions SET name=CONCAT('rc1-omitted-',id) WHERE name IN ('fleet-ops view order','fleet-ops * order','fleet-ops *');" >/dev/null
after_count=$(docker exec "$name" mysql -uroot --protocol=socket -N -B -e "SELECT COUNT(*) FROM fleetbase.permissions WHERE name IN ('fleet-ops view order','fleet-ops * order','fleet-ops *');")
[[ "$after_count" == 0 ]] || { echo RC1_MISSING_PERMISSION_RENAME=NO_GO;exit 2;}
echo RC1_MISSING_PERMISSION_CATALOG_NAMES=OMITTED_WITH_FK_INTACT
no_role_after=$(status "$no_role_minted" 'int/v1/orders/rc1-test-order-a')
reader_after=$(status "$reader_minted" 'int/v1/orders/rc1-test-order-a')
admin_after=$(status "$admin_minted" 'int/v1/orders/rc1-test-order-b')
echo "RC1_PARTIAL_CATALOG_NO_ROLE=$no_role_after READER=$reader_after ADMIN=$admin_after"
[[ "$no_role_after" == 401 && "$reader_after" == 401 && "$admin_after" == 200 ]] || { echo RC1_PARTIAL_PERMISSION_FAIL_CLOSED=NO_GO;exit 2;}
echo RC1_PARTIAL_PERMISSION_FAIL_CLOSED=PASS
# Entire order catalog omitted: the explicit order invariant must still
# deny, even though isResourceGuarded('order') becomes false.
docker exec "$name" mysql -uroot --protocol=socket -e "UPDATE fleetbase.permissions SET name=CONCAT('rc1-fully-omitted-',id) WHERE name LIKE '% order';" >/dev/null
remaining=$(docker exec "$name" mysql -uroot --protocol=socket -N -B -e "SELECT COUNT(*) FROM fleetbase.permissions WHERE name LIKE '% order';")
[[ "$remaining" == 0 ]] || { echo RC1_ALL_ORDER_PERMISSIONS_OMISSION=NO_GO;exit 2;}
no_role_full=$(status "$no_role_minted" 'int/v1/orders/rc1-test-order-a')
admin_full=$(status "$admin_minted" 'int/v1/orders/rc1-test-order-b')
echo "RC1_FULL_CATALOG_NO_ROLE=$no_role_full ADMIN=$admin_full"
[[ "$no_role_full" == 401 && "$admin_full" == 200 ]] || { echo RC1_FULL_PERMISSION_FAIL_CLOSED=NO_GO;exit 2;}
echo RC1_FULL_PERMISSION_FAIL_CLOSED=PASS

# Resource beyond order: emulate missing complete contact permission catalog,
# preserving all permission UUIDs and directives via name-only changes.
contact_before=$(docker exec "$name" mysql -uroot --protocol=socket -N -B -e "SELECT COUNT(*) FROM fleetbase.permissions WHERE name LIKE '% contact';")
[[ "$contact_before" -gt 0 ]] || { echo RC1_CONTACT_PERMISSION_CATALOG=NO_GO_ABSENT_BASELINE;exit 2; }
docker exec "$name" mysql -uroot --protocol=socket -e "UPDATE fleetbase.permissions SET name=CONCAT('rc1-contact-omitted-',id) WHERE name LIKE '% contact';" >/dev/null
contact_remaining=$(docker exec "$name" mysql -uroot --protocol=socket -N -B -e "SELECT COUNT(*) FROM fleetbase.permissions WHERE name LIKE '% contact';")
[[ "$contact_remaining" == 0 ]] || { echo RC1_CONTACT_PERMISSION_CATALOG=NO_GO_REMAINING;exit 2; }
no_role_contact=$(status "$no_role_minted" 'int/v1/contacts')
reader_contact=$(status "$reader_minted" 'int/v1/contacts')
admin_contact=$(status "$admin_minted" 'int/v1/contacts')
echo "RC1_FULL_CONTACT_CATALOG_NO_ROLE=$no_role_contact READER=$reader_contact ADMIN=$admin_contact"
[[ "$no_role_contact" == 401 && "$reader_contact" == 401 && "$admin_contact" == 200 ]] || { echo RC1_CONTACT_RESOURCE_FAIL_CLOSED=NO_GO;exit 2; }
echo RC1_CONTACT_RESOURCE_FAIL_CLOSED=PASS

echo RC1_MISSING_PERMISSION_GUARD_CANDIDATE=PASS_MULTI_RESOURCE


echo RC1_SANCTUM_HTTP_PROBE=EXECUTED

echo RC1_REAL_TWO_BEARER_HTTP_ORDER_IDOR=PASS
echo RC1_ORGANIZATION_CURRENT_ROUTE=CHECK_HTTP_STATUSES_ABOVE
echo RC1_PRODUCTION=NO_GO
