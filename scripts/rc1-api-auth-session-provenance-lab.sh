#!/usr/bin/env bash
# RC1 Core API session-company provenance diagnostic (not a real HTTP auth test).
set -euo pipefail
umask 077
[[ "$(uname -s)" == Linux && "$(id -u)" -eq 0 ]] || exit 2
[[ "$(docker image inspect fleetbase/fleetbase-api:v0.7.75 --format '{{.Id}}')" == sha256:413e497080156b692e089106c37555a1e33edabda1bb0b6f09c104b7a2c6171a ]] || exit 2
source_file=$(mktemp /dev/shm/gst-rc1-session-provenance.XXXXXXXX.php)
trap 'rm -f "$source_file"' EXIT
cat > "$source_file" <<'PHP'
<?php
require 'vendor/autoload.php';
$app = require 'bootstrap/app.php';
$app->make(Illuminate\Contracts\Console\Kernel::class)->bootstrap();
$session=$app->make('session.store');
class Rc1SyntheticUser {
  public function __construct(public ?string $company_uuid,public string $uuid){}
  public function isAdmin(): bool {return false;}
  public function isType(string $type): bool {return false;}
}
$assert=function(bool $condition,string $label): void {
  if(!$condition){echo 'RC1_SESSION_NO_GO_'.$label.PHP_EOL;exit(2);}
};
$request=Illuminate\Http\Request::create('/v1/orders','GET',['company_uuid'=>'company-forged']);
$session->forget(['company','user']);
$a=new Rc1SyntheticUser('rc1-company-a','rc1-user-a');
$assert(Fleetbase\Support\Auth::setSession($a)===true,'A_AUTH');
$assert(session('company')==='rc1-company-a','A_COMPANY');
$assert(session('user')==='rc1-user-a','A_USER');
$assert($request->query('company_uuid')!==(string)session('company'),'FORGED_COMPANY');
echo 'RC1_SESSION_A_BEARER_SUBJECT_COMPANY=PASS'.PHP_EOL;
$b=new Rc1SyntheticUser('rc1-company-b','rc1-user-b');
$assert(Fleetbase\Support\Auth::setSession($b)===true,'B_AUTH');
$assert(session('company')==='rc1-company-b','B_COMPANY');
$assert(session('user')==='rc1-user-b','B_USER');
echo 'RC1_SESSION_SWITCH_A_TO_B=PASS'.PHP_EOL;
$missing=new Rc1SyntheticUser(null,'rc1-user-missing');
$accepted=Fleetbase\Support\Auth::setSession($missing);
if($accepted===true && session('company')===null){
 echo 'RC1_SESSION_MISSING_COMPANY_ACCEPTED=CONFIRMED'.PHP_EOL;
}else{
 echo 'RC1_SESSION_MISSING_COMPANY_ACCEPTED=REJECTED'.PHP_EOL;
}
PHP
chmod 400 "$source_file"
for phase in L12 L10; do
  if [[ "$phase" == L12 ]]; then api=/root/.gst-rc1-runtime-31a6a026/repo/api
  else api=/root/.gst-rc1-legacy-67b2db64/repo/api
  fi
  [[ -f "$api/vendor/autoload.php" ]] || exit 2
  result=$(docker run --rm --network none --memory 384m --memory-swap 384m --pids-limit 96 --read-only --security-opt no-new-privileges --tmpfs /tmp:rw,nosuid,nodev,size=16m --tmpfs /fleetbase/api/storage:rw,nosuid,nodev,size=32m --tmpfs /fleetbase/api/bootstrap/cache:rw,nosuid,nodev,size=16m --mount "type=bind,source=$api,target=/fleetbase/api,readonly" --mount "type=bind,source=$source_file,target=/tmp/rc1-session.php,readonly" -w /fleetbase/api --entrypoint php -e APP_ENV=testing -e APP_KEY=base64:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA= -e DB_CONNECTION=sqlite -e DB_DATABASE=:memory: -e CACHE_DRIVER=array -e CACHE_STORE=array -e SESSION_DRIVER=array -e LOG_CHANNEL=stderr -e VIEW_COMPILED_PATH=/tmp fleetbase/fleetbase-api:v0.7.75 /tmp/rc1-session.php 2>/dev/null) || { echo "RC1_SESSION_$phase=NO_GO_RUNTIME"; exit 2; }
  [[ "$result" == *RC1_SESSION_A_BEARER_SUBJECT_COMPANY=PASS* && "$result" == *RC1_SESSION_SWITCH_A_TO_B=PASS* ]] || { echo "RC1_SESSION_$phase=NO_GO_ASSERT";exit 2; }
  echo "RC1_SESSION_$phase=PASS_SYNTHETIC_IDENTITY"
  if [[ "$result" == *RC1_SESSION_MISSING_COMPANY_ACCEPTED=CONFIRMED* ]]; then echo "RC1_MISSING_COMPANY_SESSION_$phase=ACCEPTED_SECURITY_REVIEW_REQUIRED"; else echo "RC1_MISSING_COMPANY_SESSION_$phase=REJECTED"; fi
done
echo RC1_REAL_HTTP_BEARER_AUTH=NOT_TESTED
echo RC1_PRODUCTION=NO_GO
