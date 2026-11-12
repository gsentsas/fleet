# Reproduce the local RC1 checks

Use the existing Fleet PR #11 branch and exact Composer lock. No production
configuration, data volume, API key or Firebase secret belongs in this lab.

## Prerequisites

The Mac lab used cached PHP 8.2.35 image
`gst-r13-a15r-php8235-bcmath-s12f:local`, image ID
`sha256:f474dac5fc59eb55bb06e9852b50c98dcd8562f31a9e617825b75c969edd7797`.
`Dockerfile.s92-tests` compiles pdo_mysql and pcntl without network. Its result was
`sha256:67bf6de46fa21cd2b1c002d58543a0905a3f56bb6b0ea64ce1da5fce9690f3b3`.
This cached-base requirement is specific to the Mac lab; the GitHub workflow
provides pinned PHP 8.2.35 independently. Neither is a production-runtime image.

MySQL is pinned to the registry digest in `compose.s92-tests.yml`, uses an
internal network, publishes no ports and stores database files in tmpfs.
The constant `s92_disposable_local_only` is a synthetic local password.

## Application tests

With Composer dependencies installed from the committed lock using PHP 8.2.35,
no scripts/plugins, and no manually copied vendor files:

```sh
docker build --network none -f Dockerfile.s92-tests -t gst-s92-php8235-mysql:local .
docker compose -f compose.s92-tests.yml up -d --wait mysql
docker compose -f compose.s92-tests.yml run --rm tests /fleetbase/scripts/rc1-ci-create-schemas.php
docker compose -f compose.s92-tests.yml run --rm tests artisan package:discover --no-interaction
docker compose -f compose.s92-tests.yml run --rm tests artisan migrate --force --no-interaction
docker compose -f compose.s92-tests.yml run --rm -e RC1_FULL_SCHEMA_MYSQL=1 tests vendor/bin/phpunit -c phpunit.xml tests/Feature/Rc1FullSchemaHttpTenantTest.php
docker compose -f compose.s92-tests.yml run --rm tests vendor/bin/phpunit -c phpunit.xml tests/Feature/Rc1NavigatorMySqlTest.php
docker compose -f compose.s92-tests.yml run --rm -e DB_CONNECTION=sqlite -e 'DB_DATABASE=:memory:' tests vendor/bin/phpunit -c phpunit.xml --testsuite Unit
docker compose -f compose.s92-tests.yml run --rm -e DB_CONNECTION=sqlite -e 'DB_DATABASE=:memory:' tests vendor/bin/phpunit -c phpunit.xml --testsuite Feature --exclude-group rc1-mysql-only
```

The historical quote test separately needs a fresh `rc1_ci_tenant` database and
`RC1_EPHEMERAL_MYSQL=1`, as the GitHub service definition already provides.
It creates its minimal schema and must not run inside the full-schema database.
The historical full-schema HTTP test must run before Navigator fixtures, since
it requires no existing orders. The core scope rollback intentionally refuses
to run after Navigator keys/sessions have been created.

The exact CI entrypoint is `scripts/rc1-fleetops-locked-overlay-proof.sh`; despite
its historical filename it performs a native locked install and source-reference
checks, then queue/quote proofs, without copying an overlay into vendor.

When finished, `docker compose -f compose.s92-tests.yml down` removes only this
lab's containers/network and discards their tmpfs fixture data. Do not use a
production Compose file or add a persistent data mount.

## Additional checks and limits

`python3 scripts/rc1-build-secret-proof.py` creates and removes a separate tiny
test image. It uses only synthetic credential data and verifies real Docker
context exclusion plus ephemeral BuildKit secret behavior. It does not build
the application release image. `docker build --check -f docker/Dockerfile .`
validates the production build recipe without publishing or deploying it.

`tools/pest` has a separate locked tool install for the two modified FleetOps
contract/helper files. With sibling checkouts named `s92-fleetops` and
`s92-core-api`, run its Pest binary in the lab with the application autoloader
prepended and the package's `scripts/pest-bootstrap.php`. These are synthetic
contract tests, not substitutes for the 25 real MySQL/HTTP security tests.

Gitleaks 8.30.1 scanned staged Fleet changes and both server commits with complete
redaction. Core/FleetOps had zero findings. Fleet had three generic-key alerts,
all at the exact installed-reference assertion: the three already published
40-character commit SHAs. They were explicitly triaged as public references;
the scanner exit was 1, not a falsely claimed clean scanner exit.

No phone, mobile build, complete QA acceptance, real FCM delivery, production
image build or production deployment is implied by any command above.
