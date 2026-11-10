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

**Current decision:** `S2_RESTORE=PASS`, `S3_THREE_FORK_MIGRATION_MAPPING=PASS_WITH_ONE_PENDING`, `S4_LEGACY_UPGRADE=NOT_RUN`, `S7_ROLLBACK=NOT_RUN`, `PRODUCTION=NO_GO`.
