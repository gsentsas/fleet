# RC1 S4 — legacy-to-Laravel 12 upgrade gate

**Status: NOT EXECUTED / NO-GO**. This is a preparation and preflight record, not approval to upgrade an active MySQL instance.

## Verified baseline (2026-11-10)

- Running Fleetbase on mail01: `/opt/gst-fleet`, git `67b2db6` (Laravel 10 baseline). Eight operational Docker services, no RC1 test container left behind.
- Production schema aggregates: `fleetbase` 152 tables and 394 migration records (batch 2); `fleetbase_sandbox` 138 tables and 304 migration records (batch 3); `fleetbase_storefront` 33 tables, no local `migrations` table.
- **Exact S3 source-vs-registry audit:** compare all migration filenames from the pinned Core API `f81cf74e` (`migrations/`), FleetOps `665e4fdf` (`server/migrations/`), and Storefront `b6d5961` (`server/migrations/`) against the live migration-name registers, read-only. Core **123/123** main and **123/123** sandbox; FleetOps **172/173** main and **172/173** sandbox; Storefront **55/55** main and **0/55** sandbox. The sole absent FleetOps name is `2026_11_08_000001_create_telematic_webhook_receipts_table`. Storefront's provider registers its migrations using `loadMigrationsFrom`; its **55/55 entries appear in the main** `fleetbase.migrations` table, so the missing `fleetbase_storefront.migrations` table is not by itself a fault. This comparison covers **only those three packages** (351 migration files); it does not prove accounting for other packages or actual Laravel 12 upgrade behavior.
- Restic snapshot `860ef168` (2026-11-10) restored all 3 SQL dumps in isolated MySQL 8.0.46: 152 / 138 / 33 base tables. Test container used `--network none`, no ports or bind mounts, and was removed; active production containers remained unchanged.
- RC1 run `42812781069` proved 395 package migrations on three **fresh** MySQL databases and anti-replay; it did **not** prove migration of restored Laravel 10 data.
- Host safety: 49 GiB free of 697 GiB (~94% used), ~4.9 GiB memory available, swap absent. This is a multi-tenant application host. RC1 application image not installed/pinned here.

## Preconditions before an S4 upgrade attempt

1. Use dedicated disposable host/CI runner or approved isolated compute with adequate free space and memory. The existing `gstfleet` Docker project, ports, bind mounts, volumes, network, credentials and snapshots must never be shared.
2. Build/pull **SHA-identified** RC1 API image from the exact PR #6 HEAD and verify its `api/composer.lock` and three fork pins. Do not use an `:latest` image from the production host.
3. Restore `860ef168` (or a newer formally selected snapshot) into a private fresh MySQL container with no inbound access, no source database credentials, and no writes to existing MySQL.
4. Before starting Laravel, collect schema, row-count/checksum baselines, migration names and batches for all three databases, plus Storefront-specific migration registration and connection mapping. No customer row values in job logs.
5. Disable scheduler, queues, telemetry/webhooks, external emails/SMS, payments, socket publication and outbound integrations in upgrade lab; ensure strict network egress isolation while preserving only the minimum isolated database connectivity.
6. Run only the real RC1 migration commands (including sandbox and Storefront) against restored copies, with a verification step that refuses any production hostname/volume/credential. Record SQL errors, pending migrations and schema diff; repeat migrate to prove NOOP.
7. Validate auth/IAM/IDOR, tenant isolation and webhook anti-replay receipts with sanitized test identities; confirm production data unchanged.
8. Rehearse **full rollback** on the disposable lab from the pre-upgrade database snapshot and previous application image. A code-only rollback is not enough after incompatible schema changes. Do not drop anti-replay receipt history or replay live webhooks.

## STOP criteria

Missing image digest or migration plan; insufficient disk/RAM; any production endpoint/mount/secret; unsafe outbound traffic; unknown historical migrations; failed restoration, schema/data checks or rollback.

## Consolidated evidence — 2026-11-10

- **S2 real backup SQL recovery:** encrypted Restic snapshot `860ef168` re-imported into an isolated ephemeral MySQL 8 container on mail01; 152 main + 138 sandbox + 33 Storefront base tables. No production mount, network or published port. Import test ended with ephemeral container removed and active DB container unchanged.
- **S3 package-to-registry reconciliation:** Core 123/123, FleetOps 172/173 (pending receipt migration), Storefront 55/55 recorded in main. Audit only covers these pinned three forks; other packages may have migrations.
- **S4 synthetic historical schema upgrade:** [run 42850611453](https://github.com/gsentsas/fleet/actions/runs/42850611453) SUCCESS, pinned Laravel 10 baseline (394 main migrations / 152 main tables / 138 sandbox tables) followed by pinned Laravel 12 migration on the **same three entirely synthetic MySQL databases**, followed by idempotent rerun. Main and sandbox each gained one telematics receipt table.
- **S7 synthetic SQL recovery:** [run 42850611453](https://github.com/gsentsas/fleet/actions/runs/42850611453) SUCCESS. After adding one disposable integrity-fixture table and row to each DB, pre-upgrade base table counts 153/139/34; after upgrade 154/140/34; recovered original snapshots 153/139/34. Fixture rows, schema metadata SHA-256 fingerprints (tables/columns/indexes/FKs), and migration registry recovery verified 3/3.
- **Other CI on same head:** API, Console, Install Smoke and committed Composer security audit all SUCCESS. The RC1 diagnostic workflow retains a deliberately failing publication-prevention final step.
- **Operational read-only host gate:** mail01 hosts multiple services, ~49 GiB free at 94% filesystem utilization, ~5.0 GiB available RAM, zero swap; Mac ~11 GiB free, Docker Desktop ~8.3 GB RAM. Do not build a second full Fleetbase stack on either host without capacity qualification. All eight production `gstfleet` containers remain running, backup and offsite unit results SUCCESS, no `gst-rc1*` containers remaining.

## Outstanding irreversible production gates

1. Provision or identify **dedicated private staging compute** with demonstrably adequate reserved disk/RAM and separately pinned container images. The current shared mail01 and low-free-space Mac have **not** passed this gate.
2. Restore the encrypted production snapshot **only inside the private staging trust boundary**. Keep credentials, tenant data and backups off public GitHub-hosted runners. Ensure app workers/webhooks/schedulers/email/SMS/payments and external network side effects are disabled.
3. Execute the exact RC1 Laravel 12 API against the **restored existing-data databases**. Compare row cardinality and key integrity for sensitive business tables without logging their contents; prove the receipt migration, no pending migrations, no-op second pass, IAM/IDOR and transport workflows.
4. Run a **complete application and database rollback rehearsal** in that isolated environment, including pinned old runtime and three DB recoveries. Verify no webhook replay, no data loss, and demonstrate restart/health.
5. Obtain an explicit production change gate before any merge, deployment, database migration or switch of real traffic.

**Current decision:** `S2_REAL_SQL_RESTORE=PASS`, `S3_THREE_FORK_MAPPING=PASS_WITH_ONE_PENDING`, `S4_SYNTHETIC_UPGRADE=PASS`, `S7_SYNTHETIC_SQL_RECOVERY=PASS`, `S4_REAL_DATA_UPGRADE=NOT_RUN`, `S7_FULL_APP_ROLLBACK=NOT_RUN`, `PRODUCTION=NO_GO`.


## Capacity recheck after host cleanup — 2026-11-10

A **fresh read-only** run of `scripts/rc1-private-staging-capacity-gate.sh` changed the disk assessment, not the release decision:

| Candidate | Free disk | Disk used | Available host RAM | Production services | Gate |
|---|---:|---:|---:|---|---|
| Mac Docker Desktop | ~11 GiB | ~95% | macOS host memory not attested; Docker ~7.75 GiB | none | **NO-GO** |
| `mail01` shared server | **228 GiB** | **68%** | ~5.0 GiB | **8 live `gstfleet` containers** | **NO-GO** |

The server's free disk increased considerably since the prior observation (~50 GiB). This is independently observed system capacity and **must not be attributed to our earlier cache cleanup**. The script's **disk thresholds now PASS on mail01**, but RAM and isolation gates fail. No second stack or customer-data upgrade was launched, no snapshot moved, and live production was not restarted.

**Feasible next research:** a deliberately constrained, private single-use restore/migration proof on dedicated compute or a proven isolated disposable environment with strict CPU/memory quotas, no public ports, no external side effects and independent old/new application artifacts. Such a proof still needs explicit full rollback and validated capacity. The presence of free disk alone is **not authorization** to run it on the shared production server.

**Current production decision: NO-GO.**


## S4-LAB-0: ephemeral Docker isolation proof on mail01 — 2026-11-10

**PASS for container guardrails only, NOT a production-data Laravel upgrade.** After clearing two definitively suspended old development processes, the server had approximately 6.0 GiB `MemAvailable`, no recent memory PSI pressure, 228 GiB disk free, and eight healthy/running GST Fleetbase production services.

A single **already locally available** `php:8.3-fpm-alpine` container was launched with the following deliberately conservative options:
`--network none --memory 128m --memory-swap 128m --cpus 0.50 --pids-limit 64 --read-only --cap-drop ALL --security-opt no-new-privileges:true --tmpfs /tmp:rw,noexec,nosuid,size=8m`. No bind mount, secret, backup, external network, published port, database access, Docker image build/pull, or project worktree access.

Docker `inspect` proved: `NETWORK=none`, `MEM_BYTES=134217728`, `MEM_SWAP=134217728`, `NANO_CPUS=500000000`, `PIDS=64`, `READONLY=true`, `PORTS={}`, `MOUNTS=0`. Running `php -r` inside the ephemeral container passed (`PHP_8.3`). The container was immediately removed; remaining containers using the selected PHP image: **zero**. Fleetbase app and database health checked **healthy** afterward. This is a bounded Docker security primitive proof, **not** an application upgrade or database restoration proof.

**Next prerequisite before touching real data**: obtain a separate private isolated host, or design a dedicated disposable restore workflow on sufficiently provisioned compute with a reproducible pinned Laravel 12 runtime, documented backup-data boundary, explicit no-side-effects policy, resource quotas, schema and business-data checks, and paired full rollback. Do not infer a production **GO** from this successful container test. `S4_REAL_DATA_UPGRADE=NOT_RUN`, `S7_FULL_ROLLBACK=NOT_RUN`, `PRODUCTION=NO_GO`.


## Encrypted backup metadata readiness preflight — 2026-11-10

The new **read-only** `scripts/rc1-real-backup-metadata-preflight.sh` was executed on `mail01` without changing or exporting customer data. Syntax: PASS, exit code: 0.

- `gstfleet-backup.service` and `gstfleet-offsite.service`: last result SUCCESS and both executions within 36 hours.
- Existing private Restic repository: accessible and encrypted; local metadata enumerates **9 snapshots**, newest around **14 hours** old.
- `RC1_BACKUP_METADATA_READINESS=PASS_RESTORE_STILL_REQUIRED`.
- **Not established by this preflight:** remote B2 snapshot content verification, restoreability of all three databases, data consistency after the Laravel 12 migration, application restart under Laravel 10, full-stack rollback or staging isolation. These remain **NO-GO** release requirements.

Never turn a metadata check or successful backup timer into production approval. Never send genuine backup data to public CI runners.


## Encrypted backup pack and three SQL archive integrity — 2026-11-10

The committed **read-only** script `scripts/rc1-real-backup-integrity-preflight.sh` was run via SSH against the private local Restic repository on `mail01`, with **no production MySQL connections or import, no data printed, and no offsite access**. Syntax `bash -n=PASS`, remote exit code `0`.

- `restic --no-lock check --read-data` (low I/O priority, timeout): **all 9 snapshots, all 19 data packs** checked; `no errors were found`.
- The newest daily snapshot was pinned by immutable snapshot ID, rather than using a moving `latest` selector.
- The three exports `fleetbase.sql.gz`, `fleetbase_sandbox.sql.gz`, `fleetbase_storefront.sql.gz` were each streamed from **that same snapshot** into `gzip -t`, and all **passed**.
- Archive integrity is **not** the same as valid SQL or restorable customer data. Importing all three backups into an isolated DB, schema/row integrity and complete application rollback are still **NOT TESTED**. Production remains **NO-GO**.


## Read-only structural inspection of genuine backup SQL — 2026-11-10

A pinned daily Restic snapshot (ID prefix `860ef168c572`) was streamed directly into a SQL statement counter without persisting or disclosing data. The new committed script `scripts/rc1-real-backup-sql-structure-preflight.sh` ran on mail01 with `bash -n=PASS`, exit code `0` and fail-closed expected schema counts.

| Dump | `CREATE TABLE` statements | `INSERT INTO` statements | Uncompressed bytes |
|---|---:|---:|---:|
| `fleetbase` | 152 | 50 | 8,321,796 |
| `fleetbase_sandbox` | 138 | 4 | 365,945 |
| `fleetbase_storefront` | 33 | 2 | 73,085 |

All three **structural presence checks PASS** and match the audited live table counts. These are statement counts, **not data row counts, parse validity, SQL import success, consistency, or rollback evidence**. The application and MySQL production containers were verified healthy following execution. No actual MySQL import, migration, service restart, data extraction or staging installation occurred. `PRODUCTION=NO_GO`.


## First isolated import of all three genuine backup databases — PASS (2026-11-10)

The committed `scripts/rc1-real-three-db-private-restore-lab.sh` was executed against immutable daily Restic snapshot prefix `860ef168c572` on `mail01`. **Real production SQL exports were imported into a disposable MySQL 8 container; no connection to production MySQL occurred.**

**Isolation:** Docker network `none`, no published ports, no host/project mount, read-only root filesystem; `/var/lib/mysql` was an ephemeral `tmpfs` (768 MiB maximum), container memory+swap capped at 1536 MiB, 1 CPU and 128 PIDs. `MYSQL_ALLOW_EMPTY_PASSWORD` was permitted **only** inside this networkless socket-only disposable MySQL instance. Container was removed afterward; verification showed no remaining `gst-rc1-private-restore-*` container. Production Fleetbase API/MySQL remained `running, healthy`.

**Critical diagnostic/correction:** Early attempts returned MySQL client `ERROR 2013` because `mysqladmin ping` was detecting the official image's **temporary bootstrap server**. MySQL's entrypoint intentionally shuts that server down before launching the final server; imports raced the shutdown. The script now waits for `MySQL init process done. Ready for start up.` **and** a responsive local MySQL socket. Merely raising memory limits was not the fix.

| Genuine backup restored to isolated MySQL 8 | Import result | Base tables after import |
|---|---|---:|
| `fleetbase.sql.gz` | PASS | **152** |
| `fleetbase_sandbox.sql.gz` | PASS | **138** |
| `fleetbase_storefront.sql.gz` | PASS | **33** |
| **All three** | **PASS** | **323** |

**Final execution:** `bash -n=PASS`, `RC1_RESTORE_ISOLATION=PASS`, `RC1_RESTORE_MYSQL_FINAL_START=PASS`, `RC1_REAL_THREE_DB_IMPORT=PASS_ISOLATED`, exit code **0**, automatic lab cleanup attempted and verified no leftover container.

**Remaining production gates:** Laravel 12 migration against this restored existing-data set, post-migration row counts/business invariants and full application+DB rollback with the pinned Laravel 10 runtime are **NOT RUN**. The one-shot MySQL restore succeeded, but a full private staging environment remains unqualified; no merge, tag, public CI with customer data, or live deployment. `PRODUCTION=NO_GO`.


## Three real restored SQL schemas: migration registries and relational integrity metadata — 2026-11-10

The latest committed `scripts/rc1-real-three-db-private-restore-lab.sh` was rerun against the pinned daily Restic backup, inside a single isolated socket-only MySQL 8 container (`--network none`, no published ports, read-only root filesystem, 1536 MiB memory limit, 768 MiB ephemeral MySQL tmpfs). **Result: `RC1_REAL_THREE_DB_IMPORT=PASS_ISOLATED`, exit code 0; disposable container removed, production Fleetbase API/DB still healthy.**

| Real restored database | Base tables | Tables with indexes | Foreign-key constraints | Migration registry records | Status |
|---|---:|---:|---:|---:|---|
| `fleetbase` | 152 | 152 | 329 | 394 | PASS |
| `fleetbase_sandbox` | 138 | 138 | 311 | 304 | PASS |
| `fleetbase_storefront` | 33 | 33 | 81 | No migrations table (expected) | PASS |
| **Total** | **323** | **323** | **721** | **698 in two registries** | **PASS** |

No tables were printed and no user data exported or logged. Registry record counts exactly match the previously audited production baseline. The first trial of this additional metadata assertion failed because of incorrectly escaped `printf` newlines; commit `f416e1f1` corrected only the test harness, then the complete rerun succeeded.

**Important boundary:** this is a successful **MySQL restoration plus relational-metadata consistency proof**, not Laravel 12 running on the restored databases. No RC1 application runtime, migration or full application+data rollback was executed. `PRODUCTION=NO_GO`.


## First actual Laravel 12 upgrade AND Laravel 10 CLI/database rollback rehearsal — PASS (2026-11-10)

**Real backup data, in a restricted disposable local Docker laboratory on mail01; no live production DB connection.** This extends earlier synthetic tests and does not authorize a production release.

Pinned runtime artifacts:
- Laravel 12 source SHA `31a6a026c7062b3febe2ff90d0927f16a74bf834`, pinned Composer JSON/LOCK SHA-256 values already validated by CI, PHP 8.2, dependencies installed separately with `--no-scripts --no-plugins`. Route bootstrap loaded **1,839 routes**.
- Laravel 10 historical source SHA `67b2db64c7490599aaa6c799b26d5e4de897c25c`, content exported from the exact historical Git object into a separate private directory, Composer.lock SHA-256 verified, PHP 8.2, separate locked dependencies/autoload PASS. Its historical dependencies have legacy advisories; this rehearsal is not a security approval.
- Existing three encrypted daily Restic SQL dumps were streamed locally to MySQL 8.0 in a **networkless** Docker container. All three backups were successfully imported. MySQL data was `tmpfs` only (768 MiB), no public ports, no host database mount, RAM limited to 1536 MiB. PHP CLI ran separately with `--network container:<temporary-mysql>`, no outbound network, read-only application mount and ephemeral caches, memory limited to 512 MiB.

**S4 actual upgrade results:**
| DB | Initial tables | Laravel 12 tables | Historical migration records | After Laravel 12 |
|---|---:|---:|---:|---:|
| `fleetbase` | 152 | 153 | 394 | 395 |
| `fleetbase_sandbox` | 138 | 139 | 304 | 305 |
| `fleetbase_storefront` | 33 | 33 | No registry | No registry |

`php artisan migrate:status`, `php artisan migrate --force`, and `php artisan sandbox:migrate --force` on genuine restored databases all **PASS**.

**S7 rollback rehearsal results:** Before migration, SHA-256 digests of canonical MySQL SQL dumps were captured for each database, without disclosing data. Initial rollback attempt hit MySQL `ERROR 3730` due to inter-schema foreign keys. Corrected the lab to **drop and recreate all three disposable schemas as a coordinated operation with FOREIGN_KEY_CHECKS=0 only inside the networkless disposable MySQL**, then replay the pinned Restic archives. The final run achieved:
- Three databases restored to exactly **152 / 138 / 33 tables**, with **3/3 canonical SQL content SHA-256 fingerprints identical** to the before-upgrade databases.
- Historical migration registries restored to **394 / 304**, and the RC1-only `telematic_webhook_receipts` table absent from the restored historical schema.
- **Pinned Laravel 10 CLI** `php artisan migrate:status` PASS against recovered MySQL, and `php artisan route:list --json` PASS.
- Reproducible script: `scripts/rc1-real-laravel10-rollback-rehearsal.sh`; **`RC1_S7_ISOLATED_DB_AND_LARAVEL10_CLI_ROLLBACK=PASS`**, **exit 0**.
- No leftover `gst-rc1-*` lab containers at postflight; 8/8 Fleetbase production containers remain Up, backup/offsite latest Result=success, production checkout unchanged at `67b2db64`.

**Remaining gates:** This proves a **three-DB real-data upgrade/recovery plus pinned Laravel 10 CLI boot**, NOT an end-to-end HTTP/socket/queue/worker restore, full application traffic switch or production rollback. It does not fully prove post-upgrade tenant-level business invariants or external service isolation in a real multi-container staging topology. Therefore **PR #6 remains DRAFT; production GO/NO-GO = NO-GO** until a formal dedicated staging full-stack E2E rehearsal and change approval.


## Real-data preservation across Laravel 12 migration: exact historical table row-count gate (2026-11-10)

The committed script `scripts/rc1-real-laravel10-rollback-rehearsal.sh` (change `5e2779ee`) was executed again against the same pinned encrypted real-data snapshot in the networkless disposable lab.

A new safety invariant computes SHA-256 of **exact `COUNT(*)` results from every existing historical base table** in each of `fleetbase`, `fleetbase_sandbox` and `fleetbase_storefront`, before migration and immediately after Laravel12 migrations. The `migrations` registry is excluded because one migration is legitimately added; the new telematic receipts table did not exist in the historical table set. The SQL output is hashed on the private host and **neither row data, table names nor individual counts are printed**.

- `RC1_S4_HISTORICAL_TABLE_ROW_COUNT_INVARIANTS_fleetbase=PASS`.
- `RC1_S4_HISTORICAL_TABLE_ROW_COUNT_INVARIANTS_fleetbase_sandbox=PASS`.
- `RC1_S4_HISTORICAL_TABLE_ROW_COUNT_INVARIANTS_fleetbase_storefront=PASS`.
- `RC1_S4_THREE_DATABASES_HISTORICAL_ROW_COUNTS=PASS`.
- Subsequent rollback of the three SQL databases to the pre-upgrade state: **three canonical SQL content hashes matched**.
- Pinned historical Laravel10 CLI: `artisan migrate:status` and `artisan route:list --json` both PASS on those restored databases.
- **Full script exit 0**, ephemeral container removed, production API and MySQL remain healthy.

**Scope clarification:** exact row-count equality is stronger than table counts but cannot detect altered values when the number of rows stays constant. Neither full per-row business-value diff nor actual HTTP/queue/socket/worker rollback was performed. Production remains NO-GO pending full-stack private staging validation and authorized change gate.


## Real-data values preserved after Laravel12 (all historical tables) — 2026-11-10

Committed test `scripts/rc1-real-laravel10-rollback-rehearsal.sh` at commit `063589c7` was rerun against three actual Restic-restored databases in a networkless disposable MySQL container. Before migration, it hashed **data-only MySQL dump streams with primary-key ordering** from all historical tables while explicitly omitting the `migrations` registry and the RC1-only `telematic_webhook_receipts` table. The same hashes were recomputed after Laravel12 migration. No business records, table names or hashes were emitted to public logs.

- `RC1_S4_HISTORICAL_ROW_VALUES_fleetbase=PASS`.
- `RC1_S4_HISTORICAL_ROW_VALUES_fleetbase_sandbox=PASS`.
- `RC1_S4_HISTORICAL_ROW_VALUES_fleetbase_storefront=PASS`.
- `RC1_S4_THREE_DB_HISTORICAL_ROW_VALUES=PASS`.
- Historical table `COUNT(*)` invariants also PASS for all three databases.
- Laravel12 upgrades of real restored data PASS (tables **153/139/33**, migrations **395/305**).
- Follow-on recovery restores three original SQL database images, all **3/3 full canonical SQL content fingerprints equal**, original tables **152/138/33**, migration registries **394/304**, pinned Laravel10 CLI migration status and route bootstrap both PASS.
- Full script: **exit 0**, no remaining temporary lab containers, production API/MySQL healthy.

**Limitations:** Data-only dump fingerprints capture business row values as serialized by pinned MySQL with primary-key ordering. They do not prove all integration/HTTP/socket/worker flows under real traffic; no production upgrade occurred and PR #6 stays DRAFT. The full-stack rollback gate remains NO-GO.


## Actual HTTP health checks on Laravel 12 and restored Laravel 10 — PASS (2026-11-10)

A **real HTTP server** was started for each runtime inside Docker with `--network container:<networkless-disposable-mysql>`; only the container-internal loopback address `127.0.0.1:18770` was bound. **No port was published, no external network access was available**, no production APIs or databases were called. The `GET /health` endpoint was discovered in the application's real route registry (Laravel 12: 1,839 routes).

The new HTTP probes are included in the complete, committed `scripts/rc1-real-laravel10-rollback-rehearsal.sh` (change `6ba2c950`). They use an ephemeral PHP 8.2 container with the pinned Laravel 12/10 source mounted read-only, transient storage and caches, explicit testing environment and the restored MySQL database over loopback. No HTTP bodies or customer records are printed.

- Actual encrypted Restic backups restored: **152/138/33 tables** on disposable MySQL 8.
- Laravel 12 migration PASS: **153/139/33**, migration registries **395/305**.
- Business-row values/row-count hashes after upgrade: **PASS in all three databases**.
- **Laravel 12 HTTP `GET /health` → status 200, PASS**.
- Recovery of original MySQL schema and data: **3/3 canonical SQL content hashes match**, migration registries **394/304**.
- Historical pinned Laravel 10 CLI route bootstrap and DB migration status PASS.
- **Laravel 10 HTTP `GET /health` → status 200, PASS** after restore.
- Complete script **exit 0**; ephemeral lab containers removed and production API/MySQL healthy.

**Scope:** an HTTP health smoke and database/CLI rollback are not a full end-to-end HTTP workflow, queue/worker or socket failover. These require dedicated full-stack staging with safe egress rules before releasing. `PRODUCTION=NO_GO`.


## Protected HTTP GET unauthorized checks — Laravel 12 and restored Laravel 10 (2026-11-10)

The complete, committed real-data laboratory script `scripts/rc1-real-laravel10-rollback-rehearsal.sh` (change `138f8db0`) now tests **five read-only protected HTTP GET endpoints with no credentials** while the restored MySQL database is actually available. This is important: the initial no-database experiment produced 503 and **was not counted as an authentication success**.

| Route (GET, unauthenticated) | After Laravel 12 upgrade | After restoring Laravel 10 |
|---|---:|---:|
| `/v1/orders` | **401** | **401** |
| `/v1/drivers` | **401** | **401** |
| `/v1/vehicles` | **401** | **401** |
| `/int/v1/orders` | **401** | **401** |
| `/int/v1/users` | **401** | **401** |
| `/health` | **200** | **200** |

Checks run within one networkless Docker namespace, no public ports, no credentials, no write requests, no response bodies printed. Both `RC1_L12_UNAUTHENTICATED_ROUTE_DENIAL=PASS` and `RC1_L10_UNAUTHENTICATED_ROUTE_DENIAL=PASS`. The same rehearsal preserved all historical business-row hashes after Laravel12 migration, then restored 3/3 original database SQL hashes with pinned Laravel10 CLI startup PASS. **Full script exit code 0** and no remaining lab containers; production API/MySQL stayed healthy.

**Boundary:** these are negative unauthorized GET checks, not actual authenticated API business workflows, tenant/IDOR coverage, worker processing, or socket failover. Those tests remain outstanding and production stays NO-GO.
