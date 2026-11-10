#!/usr/bin/env bash
set -euo pipefail
umask 077
[[ "$(uname -s)" == Linux && "$(id -u)" -eq 0 ]] || exit 2
[[ "$(docker image inspect fleetbase/fleetbase-api:v0.7.75 --format '{{.Id}}')" == sha256:413e497080156b692e089106c37555a1e33edabda1bb0b6f09c104b7a2c6171a ]] || exit 2
probe=$(mktemp /dev/shm/gst-rc1-two-tenants.XXXXXXXX.php)
trap 'rm -f "$probe"' EXIT
cat > "$probe" <<'PHP'
<?php
require 'vendor/autoload.php';
$app=require 'bootstrap/app.php';
$app->make(Illuminate\Contracts\Console\Kernel::class)->bootstrap();
$capsule=new Illuminate\Database\Capsule\Manager();
$capsule->addConnection(['driver'=>'sqlite','database'=>':memory:']);
$capsule->setAsGlobal();
$capsule->bootEloquent();
$capsule->schema()->create('orders',function($table){
    $table->increments('id');
    $table->string('company_uuid');
    $table->string('reference');
    $table->string('public_id');
});
config(['api.cache.enabled'=>false]);
$app->instance('db',$capsule->getDatabaseManager());
Illuminate\Support\Facades\DB::clearResolvedInstance('db');
Illuminate\Support\Facades\Schema::clearResolvedInstance('db');
class Rc1LookupOrder extends Illuminate\Database\Eloquent\Model {
    use Fleetbase\Traits\HasApiModelBehavior;
    protected $table='orders';
    protected $fillable=['company_uuid','public_id','reference'];
    public $timestamps=false;
}
class Rc1Order extends Illuminate\Database\Eloquent\Model {
    protected $table='orders';
    protected $guarded=[];
    public $timestamps=false;
}
Rc1Order::insert([
 ['company_uuid'=>'rc1-company-a','reference'=>'rc1-order-a','public_id'=>'rc1-order-a'],
 ['company_uuid'=>'rc1-company-b','reference'=>'rc1-order-b','public_id'=>'rc1-order-b'],
]);
foreach (['rc1-company-a'=>'rc1-order-a','rc1-company-b'=>'rc1-order-b'] as $company=>$expected) {
    $request=Illuminate\Http\Request::create('/v1/orders','GET',[
      'company_uuid'=>$company==='rc1-company-a'?'rc1-company-b':'rc1-company-a'
    ]);
    $session=$app->make('session.store');
    $session->put('company',$company);
    $request->setLaravelSession($session);
    $filter=new Fleetbase\FleetOps\Http\Filter\OrderFilter($request);
    $reflection=new ReflectionClass($filter);
    $property=$reflection->getParentClass()->getProperty('builder');
    $property->setAccessible(true);
    $builder=Rc1Order::query();
    $property->setValue($filter,$builder);
    $filter->queryForPublic();
    $rows=$builder->pluck('reference')->all();
    if ($rows!==[$expected]) { echo "NO_GO\n";exit(2); }
    $actual=Rc1LookupOrder::findRecordOrFail($expected);
    if ($actual->public_id!==$expected) { echo "NO_GO_LOOKUP_OWN\n";exit(2); }
    $other=$expected==='rc1-order-a'?'rc1-order-b':'rc1-order-a';
    try {
        Rc1LookupOrder::findRecordOrFail($other);
        echo "NO_GO_CROSS_COMPANY_LOOKUP\n";exit(2);
    } catch (Illuminate\Database\Eloquent\ModelNotFoundException $e) {
        // Expected denial: company UUID constraint on the real Fleetbase trait.
    }
}
echo "PASS_TWO_COMPANIES_AND_IDOR_LOOKUPS\n";
PHP
chmod 400 "$probe"
for version in L12 L10; do
    if [[ "$version" == L12 ]]; then code=/root/.gst-rc1-runtime-31a6a026/repo/api
    else code=/root/.gst-rc1-legacy-67b2db64/repo/api
    fi
    [[ -f "$code/vendor/autoload.php" ]] || exit 2
    result=$(docker run --rm --network none --memory 384m --memory-swap 384m \
      --read-only --pids-limit 96 --security-opt no-new-privileges \
      --tmpfs /tmp:rw,nosuid,nodev,size=16m \
      --tmpfs /fleetbase/api/storage:rw,nosuid,nodev,size=32m \
      --tmpfs /fleetbase/api/bootstrap/cache:rw,nosuid,nodev,size=16m \
      --mount "type=bind,source=$code,target=/fleetbase/api,readonly" \
      --mount "type=bind,source=$probe,target=/tmp/rc1-tenants.php,readonly" \
      -w /fleetbase/api --entrypoint php \
      -e APP_ENV=testing -e APP_KEY=base64:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA= \
      -e DB_CONNECTION=sqlite -e DB_DATABASE=:memory: \
      -e CACHE_DRIVER=array -e CACHE_STORE=array -e SESSION_DRIVER=array \
      -e LOG_CHANNEL=stderr -e VIEW_COMPILED_PATH=/tmp \
      fleetbase/fleetbase-api:v0.7.75 /tmp/rc1-tenants.php 2>/dev/null) || {
        echo "RC1_TENANCY_$version=NO_GO_RUNTIME"; exit 2;
      }
    [[ "$result" == PASS_TWO_COMPANIES_AND_IDOR_LOOKUPS ]] || {
      echo "RC1_TENANCY_$version=NO_GO_ASSERTION"; exit 2;
    }
    echo "RC1_TENANCY_$version=PASS_FILTER_AND_DIRECT_LOOKUP"
done
echo RC1_AUTHENTICATED_HTTP_TENANCY=NOT_TESTED
echo RC1_PRODUCTION=NO_GO
