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
