#!/usr/bin/env bash
# RC1 candidate security regression against synthetic in-memory data only.
set -euo pipefail
umask 077
[[ "$(uname -s)" == Linux && "$(id -u)" -eq 0 ]] || exit 2
candidate=/dev/shm/gst-rc1-core-fail-closed-candidate.php
[[ -f "$candidate" ]] || { echo RC1_TENANT_MUTATIONS=NO_GO_CANDIDATE_MISSING; exit 2; }
[[ "$(docker image inspect fleetbase/fleetbase-api:v0.7.75 --format '{{.Id}}')" == sha256:413e497080156b692e089106c37555a1e33edabda1bb0b6f09c104b7a2c6171a ]] || exit 2
probe=$(mktemp /dev/shm/gst-rc1-tenant-mutations.XXXXXXXX.php)
trap 'rm -f "$probe"; echo RC1_TENANT_MUTATION_SOURCE_CLEANUP=ATTEMPTED' EXIT
cat > "$probe" <<'PHP'
<?php
require 'vendor/autoload.php';
$app=require 'bootstrap/app.php';
$app->make(Illuminate\Contracts\Console\Kernel::class)->bootstrap();
config(['api.cache.enabled'=>false]);
$c=new Illuminate\Database\Capsule\Manager();
$c->addConnection(['driver'=>'sqlite','database'=>':memory:'],'mysql');
$c->getDatabaseManager()->setDefaultConnection('mysql');
$c->setAsGlobal();
$c->bootEloquent();
$app->instance('db',$c->getDatabaseManager());
Illuminate\Support\Facades\DB::clearResolvedInstance('db');
Illuminate\Support\Facades\Schema::clearResolvedInstance('db');
$c->schema()->create('orders',function ($t) {
  $t->increments('id');
  $t->string('company_uuid');
  $t->string('public_id');
  $t->string('reference')->nullable();
});
class Rc1TenantMutationModel extends Illuminate\Database\Eloquent\Model {
  use Fleetbase\Traits\HasApiModelBehavior;
  use Fleetbase\Traits\HasSessionAttributes;
  protected $table='orders';
  protected $fillable=['company_uuid','public_id','reference'];
  public $timestamps=false;
  // Synthetic fixture has no API authorization-directives catalog. This
  // override only bypasses that separate dependency; tenant query selection
  // still runs in the real Core API methods.
  public function applyDirectivesToQuery(\Illuminate\Http\Request $request, $builder) {
    return $builder;
  }
}
Rc1TenantMutationModel::insert([
  ['company_uuid'=>'rc1-a','public_id'=>'order-a','reference'=>'A'],
  ['company_uuid'=>'rc1-b','public_id'=>'order-b','reference'=>'B'],
]);
function requirePass(bool $yes,string $error): void {
  if (!$yes) { echo "RC1_ASSERT_NO_GO_$error\n"; exit(2); }
}
function mustDeny(callable $f,string $label): void {
  try { $v=$f(); } catch (Illuminate\Database\Eloquent\ModelNotFoundException $e) { return; }
  catch (Exception $e) { // updateRecordFromRequest uses a distinct not-found exception
    if ($label==='UPDATE' && str_contains($e->getMessage(),'not found')) return;
    echo "RC1_NO_GO_UNEXPECTED_$label\n";exit(2);
  }
  // Direct getById returns null; bulk and single deletion can return 0.
  if ($label==='GET' && $v===null) return;
  if (in_array($label,['REMOVE','BULK'],true) && ($v===0 || $v===false)) return;
  echo "RC1_NO_GO_ALLOWED_$label\n";exit(2);
}
$request=Illuminate\Http\Request::create('/v1/orders/order-b','PATCH');
$route=new Illuminate\Routing\Route('PATCH','v1/orders/{id}', ['uses'=>'Fleetbase\\FleetOps\\Http\\Controllers\\Api\\v1\\OrderController@update','controller'=>'Fleetbase\\FleetOps\\Http\\Controllers\\Api\\v1\\OrderController@update']);
$route->controller=new class extends Illuminate\Routing\Controller {};
$request->setRouteResolver(fn()=>$route);
$app->make('session.store')->put('company','rc1-a');
$model=new Rc1TenantMutationModel();
// Exercise the real positive-session read/update path with authorization-directive
// resolution intentionally stubbed (the fixture does not model the directives DB).
mustDeny(fn()=>$model->getById('order-b',null,$request),'GET');
mustDeny(fn()=>$model->updateRecordFromRequest($request,'order-b'),'UPDATE');
requirePass(Rc1TenantMutationModel::where('company_uuid','rc1-b')->value('reference')==='B','FOREIGN_VALUE_UNCHANGED');
// Positive read from the exact real API model trait (authorization directives
// are a separate concern and are stubbed only in this synthetic fixture).
$own=$model->getById('order-a',null,$request);
requirePass($own instanceof Rc1TenantMutationModel && $own->public_id==='order-a','OWN_GET');
echo "RC1_OWN_TENANT_READ=PASS\n";
// Change only the own order; assert that company B remains untouched.
$ownRequest=Illuminate\Http\Request::create('/v1/orders/order-a','PATCH',['reference'=>'A-updated']);
$ownRequest->setRouteResolver(fn()=>$route);
$ownRequest->setLaravelSession($app->make('session.store'));
$updated=$model->updateRecordFromRequest($ownRequest,'order-a',null,null,['return_object'=>true]);
requirePass($updated instanceof Rc1TenantMutationModel,'OWN_UPDATE_RETURN');
requirePass(Rc1TenantMutationModel::where('company_uuid','rc1-a')->value('reference')==='A-updated','OWN_UPDATE_VALUE');
requirePass(Rc1TenantMutationModel::where('company_uuid','rc1-b')->value('reference')==='B','FOREIGN_VALUE_STILL_UNCHANGED');
echo "RC1_OWN_TENANT_UPDATE=PASS\n";

mustDeny(fn()=>$model->remove('order-b'),'REMOVE');
mustDeny(fn()=>$model->bulkRemove(['order-b']),'BULK');
requirePass(Rc1TenantMutationModel::where('company_uuid','rc1-b')->count()===1,'FOREIGN_UNCHANGED');
requirePass(Rc1TenantMutationModel::where('company_uuid','rc1-a')->count()===1,'OWN_UNCHANGED');
echo "RC1_CROSS_TENANT_MUTATION_DENIAL=PASS\n";
$app->make('session.store')->forget('company');
mustDeny(fn()=>Rc1TenantMutationModel::findRecordOrFail('order-b'),'FIND');
mustDeny(fn()=>$model->getById('order-b',null,$request),'GET');
mustDeny(fn()=>$model->updateRecordFromRequest($request,'order-b'),'UPDATE');
mustDeny(fn()=>$model->remove('order-b'),'REMOVE');
mustDeny(fn()=>$model->bulkRemove(['order-b']),'BULK');
requirePass(Rc1TenantMutationModel::query()->count()===2,'NO_SESSION_MUTATIONS');
echo "RC1_MISSING_COMPANY_ALL_FIVE_PATHS_FAIL_CLOSED=PASS\n";
PHP
chmod 400 "$probe"
for version in L12 L10; do
  if [[ "$version" == L12 ]]; then code=/root/.gst-rc1-runtime-31a6a026/repo/api
  else code=/root/.gst-rc1-legacy-67b2db64/repo/api
  fi
  [[ -f "$code/vendor/autoload.php" ]] || exit 2
  log=$(mktemp /dev/shm/gst-rc1-tenant-mutations-log.XXXXXXXX)
  if docker run --rm --network none --memory 384m --memory-swap 384m \
    --read-only --pids-limit 96 --security-opt no-new-privileges \
    --tmpfs /tmp:rw,nosuid,nodev,size=16m \
    --tmpfs /fleetbase/api/storage:rw,nosuid,nodev,size=32m \
    --tmpfs /fleetbase/api/bootstrap/cache:rw,nosuid,nodev,size=16m \
    --mount "type=bind,source=$code,target=/fleetbase/api,readonly" \
    --mount "type=bind,source=$candidate,target=/fleetbase/api/vendor/fleetbase/core-api/src/Traits/HasApiModelBehavior.php,readonly" \
    --mount "type=bind,source=$probe,target=/tmp/rc1-mutations.php,readonly" \
    -w /fleetbase/api --entrypoint php \
    -e APP_RUNNING_IN_CONSOLE=false -e APP_ENV=testing \
    -e APP_KEY=base64:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA= \
    -e DB_CONNECTION=sqlite -e DB_DATABASE=:memory: \
    -e CACHE_DRIVER=array -e CACHE_STORE=array -e SESSION_DRIVER=array \
    -e LOG_CHANNEL=stderr -e VIEW_COMPILED_PATH=/tmp \
    fleetbase/fleetbase-api:v0.7.75 /tmp/rc1-mutations.php >"$log" 2>&1; then
    if grep -qx 'RC1_CROSS_TENANT_MUTATION_DENIAL=PASS' "$log" &&
       grep -qx 'RC1_MISSING_COMPANY_ALL_FIVE_PATHS_FAIL_CLOSED=PASS' "$log" &&
       grep -qx 'RC1_OWN_TENANT_READ=PASS' "$log" &&
       grep -qx 'RC1_OWN_TENANT_UPDATE=PASS' "$log"; then
      echo "RC1_$version"_MUTATION_AND_FAIL_CLOSED=PASS
    else
      echo "RC1_$version"_MUTATION_AND_FAIL_CLOSED=NO_GO_MISSING_MARKERS
      grep '^RC1_' "$log" | head -n 10 || true
      rm -f "$log"; exit 2
    fi
  else
    echo "RC1_$version"_MUTATION_AND_FAIL_CLOSED=NO_GO_RUNTIME
    grep -E 'RC1_|Error|Exception|Fatal' "$log" | head -n 12 | cut -c1-160 || true
    rm -f "$log"; exit 2
  fi
  rm -f "$log"
done
echo RC1_AUTHENTICATED_HTTP_IDOR=NOT_TESTED
echo RC1_PRODUCTION=NO_GO
