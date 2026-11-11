#!/usr/bin/env python3
"""RC1 pinned source audit: explicit exemption and non-resource search boundaries.
Does not establish comprehensive coverage of all protected routes.
"""
from pathlib import Path
root=Path("/root/.gst-rc1-runtime-31a6a026/repo/api/vendor/fleetbase")
read=lambda p:(root/p).read_text()
routes=read("fleetops-api/server/src/routes.php")
order=read("fleetops-api/server/src/Http/Controllers/Internal/v1/OrderController.php")
search=read("fleetops-api/server/src/Http/Controllers/Internal/v1/SearchController.php")
trait=read("fleetops-api/server/src/Traits/AuthorizesMethods.php")
guard=read("core-api/src/Http/Middleware/AuthorizationGuard.php")
checks={
 "EXEMPT_METHOD_ANNOTATED": "#[SkipAuthorizationCheck]\n    public function editOrderRoute" in order,
 "EXEMPT_METHOD_EXPLICIT_IAM": "'editOrderRoute'   => 'update-route-for order'" in order,
 "EXEMPT_METHOD_ROUTE": "$router->patch('route/{id}', $controller('editOrderRoute'));" in routes,
 "CUSTOM_IAM_MIDDLEWARE": "Authorization::authorize(...(array) $permissions)" in trait and "->only($method)" in trait,
 "SEARCH_PROTECTED_ROUTE": "$router->get('search', 'SearchController@search');" in routes and "'fleetbase.protected'" in routes,
 "SEARCH_NONRESOURCE_CONTROLLER": "class SearchController extends Controller" in search and "function getResourceSingularName(" not in search,
 "SEARCH_PERMISSION_CHECKS": "private function canSearchType" in search and "return Auth::can($permissions[$type]);" in search,
 "SEARCH_TENANT_FILTER": "->where('company_uuid', session('company'))" in search,
 "CURRENT_GUARD_EMPTY_CATALOG_RISK": "$requiredPermissions->isNotEmpty()" in guard,
}
for k,v in checks.items():print("RC1_"+k+"="+("PASS_SOURCE" if v else "NO_GO"))
if not all(checks.values()): raise SystemExit(2)
print("RC1_EXEMPT_AND_NONRESOURCE_SOURCE=PASS_LIMITED_SCOPE")
print("RC1_ALL_PROTECTED_NONRESOURCE_CONTROLLERS=NOT_AUDITED")
print("RC1_SECURITY_GO=NO")
