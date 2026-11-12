# RC1 S31 QA recovery — controlled plan (not an authorization)

Immutable source volume: gst-rc1-qa_qa_mysql_data.
Candidate fresh target: gst-rc1-restored-s31_qa_mysql_data.
Archive: /opt/gst-rc1-staging/qa-rollback/rc1-qa-three-schemas.sql.gz.
Archive SHA256: 7bd64ecec97fd885c25a7b47677977fb38343f591aca503570a1cead93def500.
Candidate RC1 SHA: c806c0798a6793ae2b5f6b1941a373ecb1884517.

Run the read-only script scripts/rc1-qa-isolated-recovery-preflight.sh.
It must check production still 8/8 at expected SHA, original RC1 clean,
QA 0 running, source volume present and target absent, archive and prior
restore proof, three schema markers, and at least 5 GiB available RAM.

Separate operation requires review of any execution guard; never bypass a denial.
Only after approval create a distinct target volume and isolated pinned MySQL
container with no public ports and no production or source QA volume mounts.
Import into NEW target using an approved mechanism, verify three schema table
counts and app identities, shut down, preserve source, and only then review a
QA-only Compose override and rollback path. Never delete the original volume.
No queue/scheduler start by default. Document every GO/NO-GO in issue #1.

This step does not implement SQL restoration, create volumes, start containers,
change Compose, merge, or deploy. Production remains NO-GO.
