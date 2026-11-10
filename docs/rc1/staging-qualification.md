# GST Fleetbase — RC1 staging qualification (Laravel 12)

**Status: PREPARED / NOT EXECUTED / PRODUCTION NO-GO.**
Release candidate: `gsentsas/fleet@33bce35ea5ecd71b4a29bc6fae902248ce7c450b`, PR #6 DRAFT.
This is an operator gate, not permission to deploy or merge. Never use the default Fleetbase Compose project or the production DB/filesystem for staging.

## Evidence already acquired — do not duplicate

- [RC1 Composer/MySQL run #42812781069](https://github.com/gsentsas/fleet/actions/runs/42812781069): committed lock audit PASS; three fork installation PASS; 395 MySQL migrations each on three fresh databases; identical schema SHA; rerun idempotent; anti-replay concurrency PASS. Overall RED is the intentionally failing no-publish step.
- [Real Docker install run #42810067829](https://github.com/gsentsas/fleet/actions/runs/42810067829): API and Socket source builds PASS; fresh installation and migrations PASS; API + console HTTP PASS.
- The above tests prove fresh installation, **not** data migration from the existing production schema, restore of a realistic dataset, tenant isolation, or rollback.

## Mandatory preflight (READ-ONLY until approved)

1. Confirm target host, explicit staging owner, isolated directory, full SHA, disk/RAM budgets, no active production commands. Record `docker compose ls`, ports, mounts, existing project names and images without changing them.
2. Require a staging-only Compose project name (e.g. `gst-rc1-qa`) and a directory outside `/opt/gst-fleet`. Reject any bind mount that resolves to the existing production paths, including `docker/database/mysql`, `api/.env`, or `api/storage/app`.
3. **Do not reuse `docker-compose.yml` unchanged**: it publishes host ports 3306, 38000, 4200, and 8000 and uses a relative MySQL datadir. Build a staging-specific configuration with unique volumes, localhost-only or private published ports, and no production env mounts.
4. Require private credentials generated separately for staging and avoid the example's `MYSQL_ALLOW_EMPTY_PASSWORD: "yes"`/root URL. No public mail, payments, webhooks, SMS, socket publishing, scheduled business jobs, or outbound callbacks until explicitly mocked or disabled.
5. Capture and verify a production backup/snapshot identifier and independent restore method. Restoring a production dataset into staging requires authorization, encryption, strict access controls and sensitive-data masking; do not copy live customer data by default.
6. Pin both API and Socket image digests built from the RC1 SHA (not `:latest`) and record hashes of Composer manifests, migration source, the three fork SHAs, and the exact Compose config (redacted). Do not rebuild silently during rollback.

If any check fails, STOP before container creation, import, or migration.

## Execution gates (only on an explicitly isolated staging target)

| Gate | Required proof | Fail-closed criteria |
|---|---|---|
| S1 isolation | Compose project, all container names, networks, bind mounts, volumes, host port map, DB host and credentials are isolated | Any production overlap |
| S2 recovery snapshot | Successful encrypted backup and test restore into a *separate* staging database, plus row counts/checksums and restore log | Incomplete restore, missing retention or key |
| S3 baseline | Source database schema version and critical table counts recorded before upgrade | Unknown starting state |
| S4 upgrade | Run Laravel 12 release candidate migrations only against restored staging copy; migration log complete; rerun is NOOP | Any failing/pending migration or data loss |
| S5 runtime | Source-identifiable API and Socket start; Console and API health route HTTP checks; 401/403 on unauthorized paths | Wrong SHA, unhealthy component or auth bypass |
| S6 business/security | IAM/MFA, IDOR/tenant isolation, Driver, FleetOps/TMS, Storefront, receipts and signed webhook replay (200 duplicate, 409 key/body conflict), queues/scheduler constraints | Security or data-isolation regression |
| S7 rollback | Pin previous image digests; restore staging DB from *pre-upgrade* snapshot; verify schema/rows; keep anti-replay ledger and receipts safe from resurrection | Rollback only switches images without restoring incompatible schema |
| S8 evidence/release | Evidence links, final SHA, timing, errors and GO/NO-GO documented in GitHub issue #1 and PR #6 | Any missing proof |

**Important:** Do not run `php artisan migrate:rollback` casually against the webhook receipts table. Restoring an old database snapshot can also reintroduce already-seen webhook deliveries; disable real inbound webhooks during the entire staging exercise and define a reconciliation plan before any production cutover.

## Separate production decision

Staging success is only a recommendation to consider an explicit GO. Before production: approve the final image digests, no outstanding advisory, full backup and tested restore, migration compatibility for the *current* production version, freeze window, monitoring, communication, and manual rollback authorization. PR #6 stays DRAFT and `main` unchanged until these gates are reviewed.

**Next action:** obtain the staging-only host/configuration and prove S1/S2. Never run the staging procedure automatically in GitHub Actions on the production host.
