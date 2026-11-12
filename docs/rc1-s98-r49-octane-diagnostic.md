# GST FLEETBASE — S98-R49

Decision: **NO-GO for production / active QA rollout.** This is a disposable
laboratory validation. PR #11 remains draft and unmerged. No deployment is
included. The historical curl `000` was not reproduced; its cause is unknown.

## References and protected scope

The actual branch/PR parent was `95d6d5f0c3dcc2f8d9a4d9d93a593cce9f819a94`,
not the mission's older d2801bf. Local checkout fast-forwarded cleanly after
reviewing the four intervening proxy privacy commits. Parent exact-head CI
[43235329984](https://github.com/gsentsas/fleet/actions/runs/43235329984)
was successful. The correction's own commit and exact-head CI are recorded in
issue #1 after push; the parent result does not validate the correction.

Production stays at `67b2db64c7490599aaa6c799b26d5e4de897c25c` (8 running services).
The pre-existing modifications to .dockerignore, console production environment,
console config and the untracked SMTP compose file were left intact. Active QA
stays at `c806c0798a6793ae2b5f6b1941a373ecb1884517` (4 running services). Per-run
snapshots compare container ID/image, StartedAt, restart state/count, memory
limit and published ports before/after; all are identical. There are no active
service restarts, migrations, mounts of active volumes, DNS/Plesk/firewall changes,
real driver accounts, real pairing tokens or secret injection.

The approved R29 three-schema gzip archive has SHA256
`2340e4e102ba15e782c49b6e324c961c179a80f5f6dc0dda53b23680d7159916`
and passes gzip integrity. It restores 395 migrations and zero rows in users,
companies, drivers, api_credentials and personal_access_tokens. Migration to 397
runs only in the copy. The older S31 archive was not used.

Images: API base cc959ac ID
`sha256:53ce64447e0e1989ac38a44a56e9b533b23b8b76e837660e0c74965cb83f984e`;
R43 proxy ID `sha256:9bc27f0eed3eb2a47e97b2a8c9c903651e0209ecbb1c85b30897dd36659b6b37`;
R45 proxy ID `sha256:b74372e1ac2b1e84c40d6e15865dfd6120f0bc5737b08cb1202a4b67b41fc3c9`.
Diagnostic layers are separate disposable images. Only the corrected image has
application changes; its exact image IDs and source file hashes are in the
[evidence JSON](evidence/s98-r49-octane-lab-results.json).

## Confirmed cause

The locked Octane `StartFrankenPhpCommand::writeServerOutput()` reads child
stderr, expects Caddy JSON `msg` and text `level`, and substitutes `unknown error`
when `msg` is missing. The configured Monolog JsonFormatter instead writes
`message` and a numeric level. Thus INFO, WARNING and ERROR all become the same
misleading console ERROR. Child stdout is ignored by that supervisor: the first
stdout laboratory's zero messages was lost visibility, not proof of no errors.

A lab-only handler delegated all reporting/rendering to the original handler
while recording only exception class, source basename/line, message hash,
shouldReport, phase and status. A lab-only log listener recorded only level,
caller/file/line and message hash, never arguments, messages or context values.
Neither instrumentation is installed in the corrected image or committed as
application code.

The ten initial events precede auth samples and come from `Fleetbase\Support\Telemetry`:

| Source | Actual level | Events |
|---|---|---:|
| getIpInfo, Telemetry.php:277 | WARNING | 2 |
| getOfficialRepoCommitHash, :259 | ERROR | 4 |
| isSourceModified, :219 | INFO | 2 |
| send, :90 | ERROR | 2 |

External telemetry/IP/GitHub requests are unavailable on the intentional internal
Docker network. These log events are not authentication exceptions. Their real
levels must remain visible; no telemetry error was suppressed or reclassified.

The next ten events are `Illuminate\Auth\AuthenticationException` from
Authenticate.php:101. The Fleetbase parent handler unconditionally writes ERROR
before Laravel's shouldReport() filter (false for this expected exception).
Every traced report/render completes with 401; there is no secondary exception.
The direct invalid-link response returns 403 without throwing an exception.

## Minimal correction

- `App\Logging\FrankenPhpJsonFormatter` wraps the normalized Monolog record in
  Caddy `msg` containing Octane's structured `type=raw` protocol. The actual locked
  parser dispatches this without the lossy fallback; original level, message,
  timestamp and context are preserved. No vendor patch or dependency change.
- stdout/stderr channels use that formatter; future image default becomes stderr
  because Octane does not forward child stdout. An explicit runtime stdout
  override still needs changing before any authorized rollout. File/daily channels
  retain their existing behavior. No active environment configuration is changed.
- `App\Exceptions\Handler::report()` audits expected 401/403 exceptions at NOTICE
  with only fixed event name, exception class and status. It never adds URL,
  headers, query, user IDs, exception messages or credential values. Other
  exceptions still delegate to the original parent, including genuine 500s.
- Auth middleware, routes, permissions, pairing logic and HTTP rendering are
  unchanged. Direct 403 responses retain their existing proxy/HTTP evidence;
  this change does not introduce request-body logging.

## Deterministic results

Each row below ran ten public requests, ten anonymous link-issuance requests and
ten missing-link requests, sequentially via the private proxy. All 120 measured
requests returned their expected 200/401/403 with curl exit 0. One additional
three-request diagnostic series localized startup emitters.

| Series | Channel / renderer | HTTP 200 / 401 / 403 | unknown error | Max total |
|---|---|---|---|---:|
| Original + R43 | stdout / normal | 10 / 10 / 10 | 0 (stdout lost) | 49.365 ms |
| Original + trace + R45 | stderr / normal | 10 / 10 / 10 | 10 startup + 10 auth | 40.870 ms |
| Original + trace + R45 | stderr / raw diagnostic | 10 / 10 / 10 | 0 (renderer bypass) | 64.130 ms |
| Corrected + R45 | image default stderr / normal | 10 / 10 / 10 | 0 | 60.473 ms |

The raw diagnostic option was used only to characterize the parser, never as the
correction or a proposed deployment setting. No raw request or exception logs are
published. The JSON evidence contains per-request connect/TTFB/total, curl exit,
status/body shape, response privacy headers, unknown-message deltas,
memory.current/peak/events and running/exit/OOM state. It also contains safe
structural/hash traces and cleanup/protected-state comparisons.

Corrected normal-renderer output contains 6 ERROR, 2 WARNING, 2 INFO and 11 NOTICE
records: actual errors remain observable. Additional synthetic-token queries
return 401/403; the canary is absent from both API and proxy logs. All 20 measured
sensitive responses have no-store and no-referrer. Peak API memory in this short
run is 380743680 bytes (~363.1 MiB) under a 900 MiB lab cap, with no OOM, restart,
exit or memory.events increment. This does not validate sustained memory use or
the active QA cap of 768 MiB. A curl 000 with an exit code/transport diagnostic
was not observed, so no speculative timeout or auth change was made.

## Tests and reproduction

PHP 8.2.35, Laravel 12.71.0, PHPUnit 11.5.57 from the committed lock:

- Five new diagnostic/regression tests, 64 assertions: original parser defect,
  vendor reporting order, all eight levels through the real Octane parser,
  minimal denial audit with sensitive synthetic canaries, real HTTP 401/403 and
  real 500 still reported ERROR and rendered without internals.
- Complete Unit suite: 52 tests / 200 assertions; Feature excluding guarded
  MySQL-only tests: 18 / 58, PASS.
- Fresh MySQL complete migration replay: 397 records, PASS. Navigator suite:
  25 tests / 221 assertions, including concurrent redemption, transactional
  rollback/retry, expiry, replay rejection, revocation, tenant/driver isolation
  and permission restrictions, PASS. The standalone full-schema tenant test is
  run on a fresh schema before Navigator, as required by its zero-order guard:
  **1 test / 17 assertions, PASS**. Final disposable MySQL peak 592187392 bytes,
  memory.events all zero and no OOM kill.
- Proxy source safety gate R9/R42/R45 PASS; Plesk front-door privacy remains
  explicitly NOT YET VALIDATED. PHP/Python syntax and diff whitespace checks pass.

The first local full-schema MySQL attempt hit its 768 MiB cgroup limit through
its tmpfs database/log footprint (memory.events max increased, oom/oom_kill zero).
It was stopped explicitly; exit 137 resulted from our removal, not an asserted
OOM kill or Navigator failure. The replacement uses only disposable MySQL flags:
`--skip-log-bin --performance-schema=OFF --innodb-buffer-pool-size=32M
--innodb-redo-log-capacity=64M`. No active database receives those settings. An additional tenant test attempted
after Navigator correctly refused its nonempty synthetic fixture (3 orders);
the schemas were recreated and the CI order restored, without altering the
test or weakening its guard.

For offline unit tests, mount this checkout into the cached PHP 8.2.35 test image
and run `vendor/bin/phpunit -c phpunit.xml --testsuite Unit`; use sqlite :memory:,
APP_ENV=testing, array cache/session and no network. The dedicated MySQL compose
file is `compose.s92-tests.yml`; use a unique project, no published ports and the
local-only resource override above, create fresh schemas with
`scripts/rc1-ci-create-schemas.php`, migrate, then run guarded Navigator tests
with RC1_NAVIGATOR_MYSQL=1. Never target an existing DB.

The standalone [private harness](../scripts/rc1-s98-r49-octane-private-lab.py)
checks the approved archive and empty identity tables before any HTTP call. The
operator supplies an already-built corrected image and the private work path:

```sh
python3 scripts/rc1-s98-r49-octane-private-lab.py \
  --mode fixed --log-channel image-default --repeats 10 \
  --api-image APPROVED_CORRECTED_IMAGE --proxy-image gst-rc1-httpd:95d6d5f-r45-lab \
  --work /tmp/UNIQUE_PRIVATE_S98_R49_DIRECTORY
```

It creates only randomly named labeled containers/network, private env files,
synthetic application/DB keys and tmpfs DB storage. Cleanup removes exact owned
containers/network and env file; no global prune. A derived image can be built
without downloads using the API base and COPY only Handler.php, the formatter
and logging.php to their matching application paths, plus ENV LOG_CHANNEL=stderr.
Never copy trace bootstrap/handler into that corrected image. Reruns require the
same approved host, enough available resources and explicit immutable image IDs.

## Final cleanup

All S98-R49 remote containers/networks and the local compose project were removed.
The three diagnostic/corrected derived images and remote private work directory
were removed explicitly; base/proxy images and all other projects were preserved.
The final protected-runtime snapshot equals the initial one, production's
pre-existing worktree differences are unchanged, and QA's worktree is clean.
See [cleanup proof](evidence/s98-r49-final-cleanup.json) and
[PHPUnit summaries](evidence/s98-r49-phpunit-summary.json).

## Remaining gates / S98-R50

Global **NO-GO** remains: Android TLS/WSS, privacy across Plesk proxy hops,
prolonged memory stability, physical mobile acceptance and actual Firebase
acceptance. No phone build, FCM delivery or installed version is inferred here.
S98-R50 should first validate deployment configuration/log collection and a
longer isolated soak with the corrected image, preserve 200/401/403/500 contracts,
then handle the separate mobile/Plesk gates with the applicable authorization.
Any production deployment still requires explicit GO PRODUCTION.

Issue comments: [preflight](https://github.com/gsentsas/fleet/issues/1#issuecomment-6827333820),
[diagnostic](https://github.com/gsentsas/fleet/issues/1#issuecomment-6827845715),
[correction](https://github.com/gsentsas/fleet/issues/1#issuecomment-6827961515).
