#!/usr/bin/env python3
"""Exercise Docker context exclusion and BuildKit secret persistence with synthetic data."""
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import uuid

ROOT = Path(__file__).resolve().parents[1]
image = 'gst-s94-secret-proof:' + uuid.uuid4().hex
sentinel = 'SYNTHETIC_SECRET_' + uuid.uuid4().hex


def run(*args):
    return subprocess.check_output(args, text=True, stderr=subprocess.STDOUT)


try:
    with tempfile.TemporaryDirectory(prefix='gst-s94-build-secret-') as scratch:
        work = Path(scratch)
        context = work / 'context'
        (context / 'api').mkdir(parents=True)
        shutil.copyfile(ROOT / '.dockerignore', context / '.dockerignore')
        for name in ['api/.env', 'api/auth.json', 'composer-auth.json']:
            (context / name).write_text(sentinel)
        secret = work / 'composer-auth.json'
        secret.write_text(json.dumps({'github-oauth': {'github.com': sentinel}}))
        secret.chmod(0o600)
        (context / 'Dockerfile').write_text('''FROM gst-s92-php8235-mysql:local
COPY . /context
RUN --mount=type=secret,id=composer_auth,target=/run/secrets/composer_auth \\
    php -r '$d=json_decode(file_get_contents("/run/secrets/composer_auth"),true); if (empty($d["github-oauth"]["github.com"])) exit(2);' \\
    && test ! -e /context/api/.env \\
    && test ! -e /context/api/auth.json \\
    && test ! -e /context/composer-auth.json
''')
        run('docker', 'build', '--network', 'none', '--secret', 'id=composer_auth,src=' + str(secret), '-t', image, str(context))
        run('docker', 'run', '--rm', '--network', 'none', '--read-only', '--cap-drop', 'ALL', '--security-opt', 'no-new-privileges', '--entrypoint', 'sh', image, '-c', 'test ! -e /run/secrets/composer_auth && test ! -e /context/api/.env && test ! -e /context/api/auth.json && test ! -e /context/composer-auth.json')
        history = run('docker', 'history', '--no-trunc', '--format', '{{.CreatedBy}}', image)
        config = run('docker', 'image', 'inspect', '--format', '{{json .Config}}', image)
        if sentinel in history or sentinel in config:
            raise RuntimeError('Synthetic secret persisted in image metadata')
        print('BUILD_CONTEXT_SECRET_EXCLUSION=PASS')
        print('BUILDKIT_SYNTHETIC_SECRET_MOUNT=PASS')
        print('FINAL_IMAGE_SECRET_FILE_AND_METADATA_ABSENCE=PASS')
        print('PRODUCTION_RUNTIME_IMAGE_BUILD=NOT_PERFORMED')
finally:
    subprocess.run(['docker', 'image', 'rm', image], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
