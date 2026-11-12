# Android/iOS and Firebase acceptance procedure

Status: NOT EXECUTED. No confirmed QA device or installed Navigator build.
Android Studio 2025.1 exists on the Mac; the inspected AVD folder is empty,
adb/emulator SDK tools were not found, and Xcode/simctl is unavailable. Do not
download an SDK image, enroll a paid developer account or publish an app as an
implicit consequence of this procedure.

## Prepare the client

1. Record device/emulator ID, OS, application package/bundle, version, build and
   exact source SHA. Use a dedicated QA identity and QA company.
2. Apply `patches/navigator-app-no-credential-logs.patch` to the official source
   based on `0da77ce050ad4621efc0ede115c6e2692cda2c8e`; review the two commits.
   They remove pairing URLs, driver credentials, SDK options, FCM tokens and
   OAuth responses from explicit diagnostics, and sanitize the legacy logger.
3. Run the client's existing Jest/type/build checks and install an unsigned
   emulator/debug build or an already authorized signed QA build. A source scan
   is not a successful build or device acceptance result.
4. Capture logs into a private temporary directory. Check them locally for the
   synthetic pairing key/token; do not paste them into GitHub or chat. Record
   only whether sensitive values were found, then remove test captures safely.

## Pairing and driver acceptance matrix

Use two QA companies A/B, administrators A/B and two drivers per company. Check:

- Anonymous issuance fails; a company administrator issues a 30-minute link.
- Scan in Android and iOS; verify the configured host/socket values, then login
  as a driver from the issuing company. No administrator identity is available.
- The key alone cannot read orders, create an account, dispatch or edit IAM.
- Reuse, malformed, expired and concurrent redemptions fail as specified; one
  successful pairing exists. Induced issuance failure permits a safe retry.
- Another company's driver cannot sign in using A's pairing. A driver cannot
  read/operate another driver's order, even inside the same company.
- List/receive an assigned order, start/update/complete it; verify persisted
  events. Test reconnect and offline queuing without duplicate transitions.
- Test location permission denial, foreground/background tracking, notifications
  and notification taps. Do not equate a healthy container with these checks.
- Revoke the selected pairing and verify its existing driver token is rejected
  on the next request while another pairing remains active.
- Expire the key/token with a QA test clock; confirm refusal, clear UX and safe
  relinking. Rotation requires a new QR and fresh driver login; no automatic
  silent renewal is implemented by this candidate.
- Explicitly record currently blocked features: proof uploads, manifests,
  organization switching and general profile edits. Their ownership checks and
  compatible least-privilege routes must be implemented/tested before GO.

## Firebase gsent-it

Live read-only QA inspection found no credential file at
`/opt/gst-rc1-staging/secrets-firebase-qa/gsent-it-service-account.json`, no
Firebase/ADC environment paths, no GOOGLE_CLOUD_PROJECT and no secret mount.
No private key was opened, transferred, injected or used to send a message.

1. In the authorized Firebase/Google Cloud console, verify the project is
   `gsent-it`, FCM HTTP v1 is enabled, and identify the service account and its
   exact roles. No current IAM or API-enablement success is claimed here.
2. After separate explicit secret-provisioning authorization, install a QA-only
   service-account key (or an approved workload identity), root-owned directory
   0700/file 0600, outside the checkout, read-only mounted into QA app/workers.
   Do not reuse or replace production credentials. Never add JSON/key content to
   source control, issue comments, command arguments or logs.
3. Apply the reviewed QA Firebase overlay only when deployment is authorized.
   Set GOOGLE_CLOUD_PROJECT=gsent-it and both ADC/Firebase paths to the same
   mounted QA secret. Verify project, scope, permissions and mount presence
   through metadata-only checks. The old S39 pre-start script requires zero QA
   containers; do not weaken or rerun it against the active three-service QA.
4. Register a real QA app token privately. Send one explicit test notification
   using the real queue/worker and FCM HTTP v1; record message ID, UTC timestamp,
   foreground/background receipt and tap handling without recording the token.
5. Exercise invalid/expired/unregistered token handling and a controlled worker
   retry. Verify no secret or personal data appears in logs. Rotate the QA
   credential and verify old authorization is revoked through an approved test.

All items requiring a real client, Firebase authorization, deployment or FCM
delivery remain NOT VALIDATED until those operations actually occur.
