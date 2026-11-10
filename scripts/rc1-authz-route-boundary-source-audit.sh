#!/usr/bin/env bash
# RC1 authorization boundary audit, source only, offline/read-only.
set -euo pipefail
for version in L12 L10; do
 if [[ "$version" == L12 ]];then
  root=/root/.gst-rc1-runtime-31a6a026/repo/api/vendor
 else
  root=/root/.gst-rc1-legacy-67b2db64/repo/api/vendor
 fi
 python3 - "$root" "$version" <<'PY'
import sys
from pathlib import Path
root=Path(sys.argv[1]); version=sys.argv[2]
p=lambda f:(root/f).read_text()
routes=p("fleetbase/fleetops-api/server/src/routes.php")
provider=p("fleetbase/core-api/src/Providers/CoreServiceProvider.php")
guard=p("fleetbase/core-api/src/Http/Middleware/AuthorizationGuard.php")
auth=p("fleetbase/core-api/src/Support/Auth.php")
checks={
 "PUBLIC_APIKEY_MIDDLEWARE":"'middleware' => ['fleetbase.api'" in routes and "'fleetbase.api' => [" in provider and 'AuthenticateOnceWithBasicAuth::class' in provider,
 "PUBLIC_ORDERS_GET":"'orders', 'middleware' => []" in routes and "$router->get('{id}', 'OrderController@find')" in routes,
 "PUBLIC_ORDERS_PUT":"$router->put('{id}', 'OrderController@update')" in routes,
 "PUBLIC_ORDERS_DELETE":"$router->delete('{id}', 'OrderController@delete')" in routes,
 "INTERNAL_SANCTUM":"'fleetbase.protected' => [" in provider and "'auth:sanctum'" in provider,
 "INTERNAL_AUTH_GUARD":'AuthorizationGuard::class' in provider and 'doesntHavePermissions' in guard,
 "INTERNAL_PERMISSION_LOOKUP":'resolvePermissionsFromRequest' in auth and 'Permission::findByNames' in auth,
 "INTERNAL_ORDERS_ROUTE":"'fleetbase.protected'" in routes and '$router->fleetbaseRoutes(' in routes and "'orders'," in routes,
 "GUARD_NONEMPTY_PRECONDITION":'requiredPermissions->isNotEmpty()' in guard
}
for key,passed in checks.items():
 print('RC1_'+version+'_'+key+'='+('PASS_SOURCE' if passed else 'NO_GO'))
if not all(checks.values()):raise SystemExit(2)
print('RC1_'+version+'_AUTHORIZATION_BOUNDARIES=PASS_SOURCE_ONLY')
PY
done
echo RC1_APIKEY_ROLE_MATRIX=NOT_TESTED
echo RC1_SANCTUM_ROLE_MATRIX=NOT_TESTED
echo RC1_AUTHZ_SOURCE_AUDIT=PASS
echo RC1_PRODUCTION=NO_GO
