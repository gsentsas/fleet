# RC1 S34 - Queue cutover and legacy payload contract

Status: READ-ONLY QUEUE INVENTORY PASSED at observation time; release is NO-GO.

## Verified operational environment
- Production Fleetbase checkout SHA 67b2db6, all eight containers running.
- Queue worker is gstfleet-queue-1; command php artisan queue:work.
- Queue connection configured as redis. Redis scans and INFO keyspace are
  read-only. Redis db0 had 152 keys; 92 strings and 60 sorted sets. Prefixes
  were cache / api_consumer_metrics / countryData only.
- No keys matching queue / queues patterns observed at the snapshot time.
  This is NOT proof that no failed jobs exist in a SQL table, nor proof that
  no new job will be dispatched later.
- QA original database volume preserved and QA containers stopped.

## Compatibility of pending jobs
- New FinalizeApiOrderCreation and FinalizeInternalOrderCreation payloads
  carry the company UUID. Lookup is tenant-scoped.
- Old serialized payloads missing companyUuid intentionally fail closed
  with a controlled RuntimeException. They must never be re-executed by
  guessing a tenant based only on an order UUID.
- PHPUnit on locked Laravel 12 RC1: 54 tests and 158 assertions PASS at S33,
  including old/new serialized job shapes.

## S35 read-only SQL failed-job inventory (2026-11-11)

- Production failed_jobs table exists: exactly 3 records on redis/default.
- Oldest 2026-11-06 19:28:16; newest 2026-11-06 19:46:47.
- One each: Fleetbase/FleetOps/Notifications/OrderAssigned, OrderPing,
  OrderDispatched. These are classes only, not payload disclosure.
- FinalizeApiOrderCreation: 0; FinalizeInternalOrderCreation: 0 among
  this failed-job snapshot. This does not prove future queues empty.
- No SQL write, retry, queue mutation, worker shutdown or payload export.
- Before release, investigate failure causes and notification idempotency
  separately in an isolated QA environment, keep all three records until
  explicit disposition, and recheck aggregate metrics at cutover.

## Required before cutover
1. At an agreed maintenance window, repeat read-only Redis queue inventory
   and inspect aggregate failed_jobs metadata in the approved QA or production
   read-only database connection, without dumping payload contents.
2. Stop new dispatch through an approved drain/quiesce procedure.
   Do not clear or flush Redis and do not delete or replay jobs automatically.
3. If any legacy jobs exist, reconcile their originating company from
   authenticated business records with controlled manual review; reject
   ambiguous cross-tenant jobs. Never fabricate companyUuid.
4. Verify retries and failed-job alerting using QA only with an exact RC1
   image rebuilt from approved pinned FleetOps commits.
5. Record before/after aggregate counts and proof of no unprocessed jobs,
   preserve old snapshot, verify rollback, and seek an explicit GO decision.

Do not change production, stop workers, restart queues, flush keys, or
deploy from this document. S34 is an evidence snapshot, not cutover approval.
