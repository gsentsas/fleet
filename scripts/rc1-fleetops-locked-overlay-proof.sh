#!/usr/bin/env bash
set -euo pipefail
cd api
test "$(sha256sum composer.lock | cut -d ' ' -f1)" = '3d3ae9cfb74c7b8015f83de1d01a65b950109b2815dd566b4b5d4297cc0550bd'
test "$(sha256sum composer.json | cut -d ' ' -f1)" = '3b9d892e5b94e0b42b352fa006c2ea63e551d6ab8a8e6c7c668caed3c32e4c9c'
php -r 'if (PHP_MAJOR_VERSION !== 8 || PHP_MINOR_VERSION !== 2) exit(2); echo "PHP_82=PASS\n";'
composer validate --no-check-publish
COMPOSER_NO_AUDIT=0 composer install --prefer-dist --no-scripts --no-plugins --no-progress --no-interaction --optimize-autoloader
python3 - <<'PY_CHECK'
import json
from pathlib import Path
p={x['name']:x for x in json.loads(Path('composer.lock').read_text())['packages']}
assert p['fleetbase/fleetops-api']['source']['reference']=='665e4fdf16f0344a24a273ebd1599b92ba6c2728'
print('ORIGINAL_FLEETOPS_COMPOSER_PIN=PASS')
PY_CHECK
git clone --quiet --depth 1 --branch security/rc1-service-quote-request-tenant-20261111 https://github.com/gsentsas/fleetops.git /tmp/rc1-fleetops-patch
test "$(git -C /tmp/rc1-fleetops-patch rev-parse HEAD)" = '8c39b0a99394761470643d2d17ee0a04862188bb'
for file in \
    src/Jobs/FinalizeApiOrderCreation.php \
    src/Jobs/FinalizeInternalOrderCreation.php \
    src/Models/ServiceQuote.php \
    src/Http/Controllers/Api/v1/OrderController.php \
    src/Http/Controllers/Internal/v1/OrderController.php \
    src/Http/Controllers/Api/v1/CustomerController.php; do
    test -f "vendor/fleetbase/fleetops-api/server/$file"
    cp "/tmp/rc1-fleetops-patch/server/$file" "vendor/fleetbase/fleetops-api/server/$file"
    php -l "vendor/fleetbase/fleetops-api/server/$file"
done
for proof in rc1-queue-tenant-proof.php rc1-quote-request-tenant-proof.php; do
    sed \
      -e "s#require '/fleetbase/api/vendor/autoload.php';#require 'vendor/autoload.php';#" \
      -e "s#require '/fleetbase/api/bootstrap/app.php';#require 'bootstrap/app.php';#" \
      -e "s#require '/proof/FinalizeApiOrderCreation.php';##" \
      -e "s#require '/proof/FinalizeInternalOrderCreation.php';##" \
      -e "s#require '/proof/ServiceQuote.php';##" \
      "/tmp/rc1-fleetops-patch/server/tests/$proof" > "/tmp/$proof"
    APP_ENV=testing DB_CONNECTION=sqlite DB_DATABASE=:memory: CACHE_STORE=array CACHE_DRIVER=array SESSION_DRIVER=array LOG_CHANNEL=stderr php "/tmp/$proof"
done
test "$(sha256sum composer.lock | cut -d ' ' -f1)" = '3d3ae9cfb74c7b8015f83de1d01a65b950109b2815dd566b4b5d4297cc0550bd'
test "$(sha256sum composer.json | cut -d ' ' -f1)" = '3b9d892e5b94e0b42b352fa006c2ea63e551d6ab8a8e6c7c668caed3c32e4c9c'
echo RC1_LOCKED_FLEETOPS_SECURITY_OVERLAY=PASS
