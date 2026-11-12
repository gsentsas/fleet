# GST Fleetbase RC1: S92-S99 working evidence

Release decision: **NO-GO. Do not request or perform production deployment.**
The latest user instruction also requires explicit GO before deployment; no QA
or production deployment is part of this work. These are candidate source and
local-laboratory results, not live QA acceptance.

## S92 — security candidate

Initial FleetOps `dc0dbad4cad67ee4a93ce7726418a8a53a60a82d`, core-api
`e2076d396af95dbe77823f670cd50d4f12671e0c`.
Candidate FleetOps `7f5a82f2d4be87f52bd5729e39384867af21345a`, core-api
`4235a8661e1b08ff448db86d0eaedb76e3162739`, on the existing security branches.
FleetOps draft PR #7 and core-api draft PR #3 carry the server changes.

Device identities have no admin/console privileges. Bootstrap actions are
allowlisted; driver tokens inherit the pairing's company, expiry and revocation.
Pairing writes/consumption are atomic. Exceptions roll back the key/device and
leave the link retryable. Concurrent redemptions yield one success. Driver
profiles/orders are scoped, including list-cache partitioning protection.
See the two fork documents for exact lifecycle and deliberate feature limits.

Local proof on PHP 8.2.35, Laravel 12.71.0, PHPUnit 11.5.57, MySQL 8.0.46:
25 security tests / 221 assertions, 47 Unit / 136, 18 Feature / 58. Changed
Navigator package contracts: 7 / 34 and 10 / 45. PHP lint: 18 files.
The 24/214, 47/136 and 18/58 results were re-established after native
installation from the final candidate lock, without source overlays. Exact-SHA
GitHub CI remains a separate mandatory gate.

## S93 — reproducible integration

Fleet draft PR #11 starts at `50c8a40721a804c77d8c4940924c7fc2e052fefa`.
Composer updated only the two reviewed forks. All other runtime/dev package
records and Storefront's `b6d596154370ed5770225d889363a74fab56e584` reference are
unchanged. Lock SHA-256 is `77e93ea7273e80891a8c165cd6d4b56ef7a8615dab2b0b9152875aac290de5c5`;
manifest is `2d2b3cc6f6ca6f27bb580b2d19514e52cd1816d34fb48474a82c180536681436`.
Native install performed exactly two upgrades and no additions/removals. All 702
core-api and 872 FleetOps source/migration PHP files were compared byte-for-byte
with the published commits. The full FleetOps delta from the former Composer
source is 27 commits/31 paths, incorporating the prior queue/quote protections
plus Navigator, and one new migration. The core delta adds the second migration.
Existing queue and quote executable proof scripts also pass.

The mobile changes are a portable two-commit patch from official Navigator source
`0da77ce050ad4621efc0ede115c6e2692cda2c8e`; they are not an upstream release or an
installed application. No installed version/build is known.

## S94 — quality/database gates

Composer validate succeeds with warnings about explicit commit pins and existing
constraints; initial and targeted-update audits report no advisories. On a second
fresh tmpfs MySQL instance, migrations completed with 397 migration records and
154 tables in the main schema. Existing full-schema tenant HTTP test passed
1/17; isolated quote MySQL suite passed 4/56. Both Navigator migrations were
actually rolled back before any paired keys existed, then reapplied; Navigator
25/221 passed again and a further migrate reported nothing to migrate.
The scope migration explicitly refuses rollback while scoped keys/sessions
exist, preventing a rollback from silently broadening credential access.
The MySQL lab has an internal-only Docker network, no published ports and tmpfs
database storage. No QA/production database or volume is mounted.

The separate Pest tool has its own lock (Pest 3.8.7, dependency PHPUnit 11.5.56);
the compatibility runs load application classes and report runtime PHPUnit
11.5.57. This does not replace the real application PHPUnit/MySQL gate.
No full-library Pest, PHPStan or browser/mobile-build pass is claimed. All nine
modified workflows passed actionlint with its available ShellCheck checks after
fixing deprecated action references and quoting, without disabling checks. The
Dockerfile passes BuildKit checks; both base images are pinned by inspected
registry digest. Build credentials use an ephemeral BuildKit secret, and .env,
auth files and cached PHP config are excluded from build contexts. A real
synthetic build verified exclusion and absence from final image metadata/files.
This small security proof is not a production-runtime image build. Existing ERD
Python tests pass 4/4; synthetic Firebase preflight cases pass 10/10, with no
real key access.

## S95 — business acceptance

Local real HTTP login, session revocation, tenant/driver isolation, assigned-order
lists and negative authorization have proof. Complete QA console/admin MFA,
dispatch, order events, proof uploads, queues/scheduler, socket client and offline
mobile flows remain untested on the candidate. Restricted mobile features remain
an explicit blocker. No QA ACCEPTANCE PASS.

## S96 — Firebase

QA has no service-account file, project/environment paths or Firebase mount.
No real key injected, IAM reviewed or notification sent. The synthetic existing
Firebase preflight tests run independently of actual authorization/delivery.
Follow `rc1-mobile-firebase-acceptance.md`; FCM delivery remains NOT VALIDATED.

## S97 — read-only infrastructure observations

Verified live production SHA `67b2db64c7490599aaa6c799b26d5e4de897c25c`, eight
running containers. Published application ports are loopback only: 18080 HTTP,
14200 console, 13800 socket. MySQL/Redis have no host publications. QA SHA
`c806c0798a6793ae2b5f6b1941a373ecb1884517`, clean worktree, only app/DB/cache,
no host-published ports. QA worker/scheduler/socket/console acceptance is absent.
Host has about 188 GiB disk available and 5.4 GiB RAM available, no swap.

Public console and API health returned HTTP 200 with TLS verification success.
All three public names negotiated TLS 1.3; certificates expire 2 February 2027.
The unauthenticated WebSocket root returned 404, and a socketcluster upgrade
request returned 403; neither proves an authenticated WebSocket session works.
No container error lines were present in the bounded recent sample; historical
Octane errors remain unresolved by that observation.

The QA rollback archive still has SHA-256
`7bd64ecec97fd885c25a7b47677977fb38343f591aca503570a1cead93def500` and passes gzip
integrity. No restoration or new production backup was performed. Backup age,
off-site retention, operational restoration and current production recoverability
remain release gates. Plesk generated configs contain raw request-URI/access-log
directives. Redaction/suppression of Navigator pairing query strings across every
proxy hop is not validated and no production config was changed.

## S98 — candidate QA deployment/acceptance

NOT EXECUTED. Candidate images/digests, matching sources/lock, backup, controlled
migrations and isolated rollback need validation before an authorized QA rollout.
Production and active QA retain their original SHAs and services. No container
healthy status is counted as a business test.

## S99 — GO decision dossier

NO-GO; no GO request. Mandatory open items include exact-candidate completed CI,
immutable production-runtime images, complete schema/rollback review, live
authenticated QA business acceptance, administrator MFA, complete driver/proof/
manifest features, mobile release with safe logs, Firebase authorization and real
delivery, proxy-log privacy, current backups/restoration, supervision and an
approved rollout/rollback window. S100/S101 remain unauthorized and unexecuted.

Every stage's observations and remaining work are tracked in
https://github.com/gsentsas/fleet/issues/1. Re-read that issue and exact branch heads
before resuming; evidence from an earlier commit is never transferred to a newer
candidate without verification.
