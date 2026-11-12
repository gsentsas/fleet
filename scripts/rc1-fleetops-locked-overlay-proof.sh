#!/usr/bin/env bash
set -euo pipefail
cd api
test "$(sha256sum composer.lock | cut -d ' ' -f1)" = '77e93ea7273e80891a8c165cd6d4b56ef7a8615dab2b0b9152875aac290de5c5'
test "$(sha256sum composer.json | cut -d ' ' -f1)" = '2d2b3cc6f6ca6f27bb580b2d19514e52cd1816d34fb48474a82c180536681436'
php -r 'if (PHP_VERSION !== "8.2.35") exit(2); echo "PHP_8235=PASS\n";'
composer validate --no-check-publish
COMPOSER_NO_AUDIT=0 composer install --prefer-dist --no-scripts --no-plugins --no-progress --no-interaction --optimize-autoloader
php -r '
$p = array_column(json_decode(file_get_contents("vendor/composer/installed.json"), true)["packages"], null, "name");
$expected = ["fleetbase/core-api" => "4235a8661e1b08ff448db86d0eaedb76e3162739", "fleetbase/fleetops-api" => "7f5a82f2d4be87f52bd5729e39384867af21345a", "fleetbase/storefront-api" => "b6d596154370ed5770225d889363a74fab56e584"];
foreach ($expected as $name => $sha) { if (($p[$name]["source"]["reference"] ?? null) !== $sha) { fwrite(STDERR, "STOP=INSTALLED_SOURCE_REFERENCE_MISMATCH\n"); exit(2); } }
echo "RC1_EXACT_INSTALLED_FORK_PINS=PASS\n";'
for proof in rc1-queue-tenant-proof.php rc1-quote-request-tenant-proof.php; do
    sed \
      -e "s#require '/fleetbase/api/vendor/autoload.php';#require 'vendor/autoload.php';#" \
      -e "s#require '/fleetbase/api/bootstrap/app.php';#require 'bootstrap/app.php';#" \
      -e "s#require '/proof/FinalizeApiOrderCreation.php';##" \
      -e "s#require '/proof/FinalizeInternalOrderCreation.php';##" \
      -e "s#require '/proof/ServiceQuote.php';##" \
      "vendor/fleetbase/fleetops-api/server/tests/$proof" > "/tmp/$proof"
    APP_ENV=testing DB_CONNECTION=sqlite DB_DATABASE=:memory: CACHE_STORE=array CACHE_DRIVER=array SESSION_DRIVER=array LOG_CHANNEL=stderr php "/tmp/$proof"
done
test "$(sha256sum composer.lock | cut -d ' ' -f1)" = '77e93ea7273e80891a8c165cd6d4b56ef7a8615dab2b0b9152875aac290de5c5'
test "$(sha256sum composer.json | cut -d ' ' -f1)" = '2d2b3cc6f6ca6f27bb580b2d19514e52cd1816d34fb48474a82c180536681436'
echo RC1_LOCKED_FLEETOPS_SECURITY_PACKAGES=PASS
