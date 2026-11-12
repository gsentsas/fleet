#!/usr/bin/env python3
"""S41 isolated contract tests for S39 Bash script; synthetic keys only."""
import json
import os
import pathlib
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
SCRIPT = (ROOT / 'scripts/rc1-firebase-qa-secret-preflight.sh').read_text()
OVERLAY = (ROOT / 'deploy/compose.firebase.qa.yml').read_text()

def test_case(case, expected, mutation=None):
    with tempfile.TemporaryDirectory(prefix='gst-rc1-firebase-s41-') as scratch:
        base = pathlib.Path(scratch)
        qa = base / 'qa'
        qa.mkdir(mode=0o700)
        secret_dir = qa / 'secrets-firebase-qa'
        secret_dir.mkdir(mode=0o700)
        key = secret_dir / 'gsent-it-service-account.json'
        key.write_text(json.dumps({'project_id':'gsent-it','type':'service_account','private_key':'SYNTHETIC-TEST-ONLY'}))
        key.chmod(0o600)
        main = qa / 'compose.qa.yml'
        main.write_text('name: gst-rc1-qa\nservices: {}\n')
        repo = base / 'repo'
        (repo / 'scripts').mkdir(parents=True)
        (repo / 'deploy').mkdir()
        overlay = repo / 'deploy/compose.firebase.qa.yml'
        overlay.write_text(OVERLAY.replace('/opt/gst-rc1-staging/secrets-firebase-qa',str(secret_dir)))
        script = repo / 'scripts/rc1-firebase-qa-secret-preflight.sh'
        script.write_text(SCRIPT.replace('/opt/gst-rc1-staging',str(qa)))
        binaries = base / 'bin'
        binaries.mkdir()
        git = binaries / 'git'
        git.write_text('#!/bin/sh\nprintf \"67b2db6\"\n')
        git.chmod(0o755)
        docker = binaries / 'docker'
        docker.write_text('#!/bin/sh\ncase "$*" in *gst-rc1-qa*) : ;; *) for i in 1 2 3 4 5 6 7 8; do echo simulated-container-id; done ;; esac\n')
        docker.chmod(0o755)
        if mutation:
            mutation(key, secret_dir, main, overlay)
        env = dict(os.environ, PATH=str(binaries) + os.pathsep + os.environ['PATH'])
        proc = subprocess.run(['bash',str(script)],text=True,capture_output=True,env=env,timeout=12)
        output = proc.stdout + proc.stderr
        assert expected in output, f'{case}: expected {expected}, got exit={proc.returncode} output={output[:220]}'
        assert proc.returncode == (0 if expected == 'S39_QA_FIREBASE_PREFLIGHT=PASS_READ_ONLY' else (2 if expected in ('STOP=QA_FIREBASE_KEY_NOT_PROVISIONED', 'STOP=PRODUCTION_SHA_DRIFT', 'STOP=PROD_SERVICE_COUNT', 'STOP=QA_ALREADY_RUNNING', 'STOP=QA_COMPOSE_MISSING') else 1)), f'{case}: exit={proc.returncode}'
        print('S41_CASE_' + case + '=PASS')

def main():
    test_case('GOOD_SYNTHETIC', 'S39_QA_FIREBASE_PREFLIGHT=PASS_READ_ONLY')
    test_case('MISSING_SECRET','STOP=QA_FIREBASE_KEY_NOT_PROVISIONED',lambda k,d,m,o: k.unlink())
    test_case('WRONG_PROJECT','STOP=QA_FIREBASE_IDENTITY_INVALID',lambda k,d,m,o: k.write_text(json.dumps({'project_id':'wrong','type':'service_account','private_key':'FAKE'})))
    test_case('WRONG_TYPE','STOP=QA_FIREBASE_IDENTITY_INVALID',lambda k,d,m,o: k.write_text(json.dumps({'project_id':'gsent-it','type':'user','private_key':'FAKE'})))
    test_case('INSECURE_FILE','STOP=SECRET_PERMISSIONS_TOO_BROAD',lambda k,d,m,o: k.chmod(0o644))
    test_case('INSECURE_FOLDER','STOP=SECRET_DIRECTORY_TOO_OPEN',lambda k,d,m,o: d.chmod(0o755))
    test_case('WRONG_COMPOSE','STOP=WRONG_COMPOSE_PROJECT',lambda k,d,m,o: m.write_text('name: gstfleet\n'))
    test_case('MISSING_READONLY','STOP=SECRET_MOUNTS_NOT_READONLY',lambda k,d,m,o: o.write_text(o.read_text().replace('read_only: true','read_only: false',1)))
    test_case('WRONG_OVERLAY_PROJECT','STOP=PROJECT_NOT_PINNED',lambda k,d,m,o: o.write_text(o.read_text().replace('GOOGLE_CLOUD_PROJECT: gsent-it','GOOGLE_CLOUD_PROJECT: wrong',1)))
    test_case('SECRET_SOURCE_DRIFT','STOP=SECRET_SOURCE_DRIFT',lambda k,d,m,o: o.write_text(o.read_text().replace('source: '+str(k),'source: /wrong/source',1)))
    print('S41_TOTAL=10_OF_10_PASS')
    print('S41_REAL_KEYS_ACCESSED=NO')
    print('S41_DOCKER_PRODUCTION_ACCESSED=NO')

if __name__ == '__main__':
    main()
