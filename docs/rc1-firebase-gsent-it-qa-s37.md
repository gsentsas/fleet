# RC1 S37 — Firebase gsent-it QA configuration

Firebase project gsent-it, FCM v1 enabled, service-account JSON present
on user Mac. Local JSON metadata confirms service_account and project_id.
No private key content was printed.

An attempt to transfer credentials to the server was blocked by a security
control. Do not circumvent that denial. Key is not installed on server.

QA-only optional override: deploy/compose.firebase.qa.yml.
Source key path not yet present: /opt/gst-rc1-staging/secrets-firebase-qa/gsent-it-service-account.json.
Container read-only path: /run/secrets/gst-firebase-qa.json.
Environment: GOOGLE_CLOUD_PROJECT=gsent-it, FIREBASE_CREDENTIALS and
GOOGLE_APPLICATION_CREDENTIALS. No credential in Git or Docker images.

Required next actions:
- Use an approved secret provisioning mechanism and do not bypass controls.
- Protect the key with least privileges and verify project_id privately.
- Restore QA database to a distinct clean volume before starting any QA app.
- With isolated QA only, test Firebase factory boot without sending a push.
- Test later only with a designated nonproduction device token.
- Keep workers stopped, do not retry production failed_jobs.
- Production remains untouched and NO-GO.

STATUS: overlay prepared; QA secret not installed; Firebase not started.

## S40 — Mac-side offline credential integrity gate (2026-11-11)

Executed locally on the user's authorized Mac, not on QA or production.
Validated gsent-it Firebase Admin service-account JSON metadata without
printing the key, client_email or token. Exact boolean-only checks PASS:
project_id matches gsent-it, type is service_account, client-email
domain corresponds to gsent-it IAM service account, client_id and
private_key_id present, token_uri host is oauth2.googleapis.com,
file is mode 0600, PEM boundary valid and OpenSSL pkey -check succeeds.
No Firebase network request, no transfer to server, no notification sent.

Note: this establishes local key format/integrity and project metadata
consistency only. It does NOT prove account has active permissions in
Google Cloud, Firebase delivery or server config. Earlier credential
transfer was explicitly denied; do not circumvent that denial.
QA service-account remains absent, and the S39 preflight intentionally
fails closed. QA database restore and authenticated HTTP gates remain open.

S40_OFFLINE_ACCOUNT_INTEGRITY=PASS
S40_SERVER_PROVISIONING=BLOCKED
S40_PRODUCTION=NO_GO
