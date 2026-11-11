#!/usr/bin/env bash
# S31: read-only checks; no volume creation, SQL, container start or cleanup.
set -euo pipefail
old=gst-rc1-qa_qa_mysql_data
new=gst-rc1-restored-s31_qa_mysql_data
archive=/opt/gst-rc1-staging/qa-rollback/rc1-qa-three-schemas.sql.gz
proof=/opt/gst-rc1-staging/qa-rollback/restore-proof.json
manifest=/opt/gst-rc1-staging/qa-rollback/manifest.json
[[ "$(git -C /opt/gst-fleet rev-parse --short HEAD)" == 67b2db6 ]] || { echo STOP=PRODUCTION_SHA_DRIFT; exit 2; }
[[ "$(git -C /opt/gst-rc1-staging/repo rev-parse HEAD)" == c806c0798a6793ae2b5f6b1941a373ecb1884517 ]] || { echo STOP=RC1_SHA_DRIFT; exit 2; }
[[ -z "$(git -C /opt/gst-rc1-staging/repo status --porcelain)" ]] || { echo STOP=RC1_DIRTY; exit 2; }
[[ "$(docker ps -q --filter label=com.docker.compose.project=gstfleet | wc -l | tr -d ' ')" == 8 ]] || { echo STOP=PROD_NOT_EIGHT; exit 2; }
[[ "$(docker ps -q --filter label=com.docker.compose.project=gst-rc1-qa | wc -l | tr -d ' ')" == 0 ]] || { echo STOP=QA_RUNNING; exit 2; }
docker volume inspect "$old" >/dev/null
if docker volume inspect "$new" >/dev/null 2>&1; then echo STOP=TARGET_ALREADY_EXISTS; exit 2; fi
[[ "$old" != "$new" ]] || { echo STOP=VOLUME_COLLISION; exit 2; }
[[ "$(sha256sum "$archive" | cut -d ' ' -f1)" == 7bd64ecec97fd885c25a7b47677977fb38343f591aca503570a1cead93def500 ]] || { echo STOP=ARCHIVE_CHANGED; exit 2; }
gzip -t "$archive"
python3 - "$archive" "$manifest" "$proof" <<'PYCODE'
import gzip,json,pathlib,sys
archive,manifest,proof=sys.argv[1:]
m=json.loads(pathlib.Path(manifest).read_text())
p=json.loads(pathlib.Path(proof).read_text())
assert m['sha256']==p['archive_sha256']
assert m['candidate_sha']==p['candidate_sha']=='c806c0798a6793ae2b5f6b1941a373ecb1884517'
assert m['source_volume']=='gst-rc1-qa_qa_mysql_data'
assert p['network']=='none' and p['three_schemas_present'] is True
names=['gst_rc1_qa','gst_rc1_qa_storefront','gst_rc1_qa_sandbox']
assert m['schemas']==names
with gzip.open(archive,'rt') as f:
    data=f.read()
for name in names:
    assert 'USE '+chr(96)+name+chr(96)+';' in data
assert 'DROP DATABASE' not in data.upper()
print('S31_ARCHIVE_AND_RESTORE_PROOF=PASS')
print('S31_THREE_SCHEMA_MARKERS=PASS')
PYCODE
available=$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)
if (( available < 5242880 )); then
  echo "S31_MEM_AVAILABLE_KIB=$available"
  echo STOP=HOST_RAM_BELOW_5_GIB
  exit 2
fi
echo "S31_PRESERVED_SOURCE_VOLUME=$old"
echo "S31_EMPTY_TARGET_NAME=$new"
echo S31_PREFLIGHT=PASS_READ_ONLY
echo S31_OPERATIONAL_RESTORE=NOT_RUN_SAFETY_REVIEW_REQUIRED
