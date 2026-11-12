#!/usr/bin/env bash
# S39 QA Firebase: read-only checks; never copies keys or starts services.
set -euo pipefail
root=/opt/gst-rc1-staging
secret=$root/secrets-firebase-qa/gsent-it-service-account.json
main=$root/compose.qa.yml
overlay=$(cd "$(dirname "$0")/.." && pwd)/deploy/compose.firebase.qa.yml
[[ "$(git -C /opt/gst-fleet rev-parse --short HEAD)" == 67b2db6 ]] || { echo STOP=PRODUCTION_SHA_DRIFT; exit 2; }
[[ "$(docker ps -q --filter label=com.docker.compose.project=gstfleet | wc -l | tr -d ' ')" == 8 ]] || { echo STOP=PROD_SERVICE_COUNT; exit 2; }
[[ "$(docker ps -q --filter label=com.docker.compose.project=gst-rc1-qa | wc -l | tr -d ' ')" == 0 ]] || { echo STOP=QA_ALREADY_RUNNING; exit 2; }
[[ -f "$main" && -f "$overlay" ]] || { echo STOP=QA_COMPOSE_MISSING; exit 2; }
[[ -f "$secret" && ! -L "$secret" ]] || { echo STOP=QA_FIREBASE_KEY_NOT_PROVISIONED; exit 2; }
python3 - "$secret" "$main" "$overlay" <<'PYCODE'
import json,os,pathlib,stat,sys
key,base,overlay=map(pathlib.Path,sys.argv[1:])
if key.is_symlink() or not key.is_file(): raise SystemExit('STOP=SECRET_SYMLINK_OR_INVALID')
if stat.S_IMODE(key.stat().st_mode) & 0o077: raise SystemExit('STOP=SECRET_PERMISSIONS_TOO_BROAD')
if stat.S_IMODE(key.parent.stat().st_mode) & 0o077: raise SystemExit('STOP=SECRET_DIRECTORY_TOO_OPEN')
if key.stat().st_size > 16384: raise SystemExit('STOP=UNEXPECTED_SECRET_SIZE')
data=json.loads(key.read_text())
if data.get('project_id')!='gsent-it' or data.get('type')!='service_account' or not data.get('private_key'):
    raise SystemExit('STOP=QA_FIREBASE_IDENTITY_INVALID')
base_text=base.read_text(); over=overlay.read_text()
if not base_text.startswith('name: gst-rc1-qa'): raise SystemExit('STOP=WRONG_COMPOSE_PROJECT')
if over.count('read_only: true')!=2: raise SystemExit('STOP=SECRET_MOUNTS_NOT_READONLY')
if over.count('GOOGLE_CLOUD_PROJECT: gsent-it')!=2: raise SystemExit('STOP=PROJECT_NOT_PINNED')
if over.count('FIREBASE_CREDENTIALS: /run/secrets/gst-firebase-qa.json')!=2: raise SystemExit('STOP=FIREBASE_PATH_INCOMPLETE')
if over.count('GOOGLE_APPLICATION_CREDENTIALS: /run/secrets/gst-firebase-qa.json')!=2: raise SystemExit('STOP=ADC_PATH_INCOMPLETE')
if over.count('source: '+str(key))!=2: raise SystemExit('STOP=SECRET_SOURCE_DRIFT')
print('S39_QA_SECRET_IDENTITY_AND_PERMISSIONS=PASS')
print('S39_QA_COMPOSE_SCOPE_AND_MOUNTS=PASS')
PYCODE
echo S39_QA_FIREBASE_PREFLIGHT=PASS_READ_ONLY
echo S39_QA_CONTAINER_START=NOT_PERFORMED
