# RC1 S36 — Firebase notification failure: evidence and remediation gate

## Production read-only evidence (2026-11-11)

- Fleetbase production still SHA 67b2db6 with 8/8 services running; QA
  remains stopped. No jobs replayed or deleted.
- In production MySQL failed_jobs there are three historical records
  on redis/default (2026-11-06): OrderAssigned, OrderPing, OrderDispatched.
- First exception on all three is a RuntimeException whose text contains
  `Unable to determine the Firebase Project ID`; exceptions have the same
  SHA256 digest, indicating a common failure mode.
- Matching exception is thrown from installed vendor
  `kreait/firebase-php/src/Firebase/Factory.php` when the Firebase project ID
  cannot be determined. This is an **actual runtime configuration defect**
  for Firebase push notifications. It is not evidence of a queue serialization
  defect or a failed tenant-scoped finalization job.
- Queue container environment-variable name inventory found no names
  containing FIREBASE, FCM, GOOGLE, APN, PUSH or NOTIFICATION. This does
  not prove that no secrets/config are supplied by files or config cache.
- No `config/firebase.php` or `config/fcm.php` files found in the running
  application container; `config/services.php` exists. No secrets read.

## Safe prerequisites before resolving

1. Determine the intended Firebase project for this deployment from the
   owner-approved administrative configuration. Do not guess a project ID
   or copy credentials from another tenant/project.
2. Verify a secure source for service-account credentials and project ID
   (protected server secret/configuration, not git). Review config caching
   and permissions. Never paste private keys into GitHub logs or issues.
3. In isolated QA, test Firebase factory initialization with the expected
   project ID *without* sending a push. Then test delivery with approved
   non-production device tokens, verify tenant recipient separation and
   notification idempotency; keep mail/APNs separate.
4. After the QA gate and explicit operational approval, prepare a targeted
   production configuration update with backup and rollback; do not change
   the running production environment during this diagnostic stage.
5. Preserve all three failed_jobs rows. Only consider an explicitly reviewed
   replay or separate remediation of these historical notifications after
   user-recipient privacy and idempotence are verified. Do not blindly retry.

## Status

S36_CAUSE=FIREBASE_PROJECT_ID_UNRESOLVED
S36_QA_VERIFIED=NO
S36_PRODUCTION_CONFIGURATION_CHANGED=NO
S36_FAILED_JOBS_MUTATED=NO
S36_RELEASE=NO_GO
