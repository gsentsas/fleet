#!/usr/bin/env python3
"""S98-R49 disposable stack; requires the approved, identity-empty R29 archive.

Run only on the authorized lab host. Raw mode is a diagnostic opt-in inside the
internal network; only structural/hash summaries are exported, never raw logs.
The caller builds the candidate image separately; this script never builds,
pulls, publishes, migrates, stops or restarts an active environment.
"""
import argparse
import collections
import gzip
import hashlib
import json
import os
from pathlib import Path
import secrets
import subprocess
import time

PARSER = argparse.ArgumentParser()
PARSER.add_argument('--mode', choices=['baseline', 'trace', 'raw', 'fixed'], default='baseline')
PARSER.add_argument('--api-image', default='gst-rc1-api:cc959ac-amd64')
PARSER.add_argument('--proxy-image', default='gst-rc1-httpd:d2801bf-r43-lab')
PARSER.add_argument('--memory', default='900m')
PARSER.add_argument('--log-channel', choices=['stdout', 'stderr', 'image-default'], default='image-default')
PARSER.add_argument('--repeats', type=int, default=10)
PARSER.add_argument('--work', required=True)
ARGS = PARSER.parse_args()
WORK = Path(ARGS.work).resolve()
WORK.mkdir(mode=0o700, parents=True, exist_ok=True)
os.chmod(WORK, 0o700)
PREFIX = 'gst-s98-r49-' + secrets.token_hex(4)
NAMES = {key: PREFIX + '-' + key for key in ['mysql', 'redis', 'api', 'httpd']}
NETWORK = PREFIX + '-net'
ARCHIVE = Path('/opt/gst-rc1-staging/qa-rollback/s98-r29-current/qa-three-schemas.sql.gz')
EXPECTED_ARCHIVE = '2340e4e102ba15e782c49b6e324c961c179a80f5f6dc0dda53b23680d7159916'
CREATED = []
RESULT = {'mode': ARGS.mode, 'prefix': PREFIX, 'api_image': ARGS.api_image, 'proxy_image': ARGS.proxy_image, 'memory': ARGS.memory, 'log_channel': ARGS.log_channel, 'samples': []}


def command(args, *, data=None, timeout=120, allow_failure=False):
    result = subprocess.run(args, input=data, capture_output=True, text=True, timeout=timeout)
    if result.returncode and not allow_failure:
        # Never include commands/env, SQL diagnostics or exception messages.
        raise RuntimeError('command_failed:' + args[0] + ':exit=' + str(result.returncode))
    return result


def docker(*args, **kwargs):
    return command(['docker', *args], **kwargs)


def inspect(name):
    return json.loads(docker('inspect', name).stdout)[0]


def protected_snapshot():
    ids = []
    for project in ['gstfleet', 'gst-rc1-qa']:
        ids += docker('ps', '-q', '--filter', 'label=com.docker.compose.project=' + project).stdout.split()
    rows = {}
    for cid in ids:
        c = inspect(cid)
        rows[c['Name']] = {k: c['State'][k] for k in ['Running', 'StartedAt', 'Restarting']}
        rows[c['Name']].update({'id': c['Id'], 'image': c['Image'], 'restart_count': c['RestartCount'], 'memory_limit': c['HostConfig']['Memory'], 'ports': c['HostConfig']['PortBindings']})
    return rows


def launch(key, image, options, entry=None):
    args = ['run', '-d', '--name', NAMES[key], '--label', 'gst.scope=s98-r49', '--network', NETWORK, *options]
    if entry:
        args += ['--entrypoint', entry]
    args += [image]
    CREATED.append(NAMES[key])
    return args


def sql(query):
    return docker('exec', NAMES['mysql'], 'sh', '-c', 'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" exec mysql -uroot --batch --skip-column-names -e "$1"', 'sh', query).stdout.strip()


def logs():
    r = docker('logs', NAMES['api'], allow_failure=True)
    return r.stdout + r.stderr


def memory():
    c = inspect(NAMES['api'])
    out = {'running': c['State']['Running'], 'exit_code': c['State']['ExitCode'], 'oom_killed': c['State']['OOMKilled'], 'restart_count': c['RestartCount']}
    if out['running']:
        r = docker('exec', NAMES['api'], 'sh', '-c', 'for f in memory.current memory.peak memory.events cpu.stat; do echo "FIELD=$f"; cat "/sys/fs/cgroup/$f"; done', allow_failure=True)
        field = None
        for line in r.stdout.splitlines():
            if line.startswith('FIELD='):
                field = line[6:]
                out[field] = {} if field in ['memory.events', 'cpu.stat'] else None
            elif field in ['memory.events', 'cpu.stat']:
                k, v = line.split()
                out[field][k] = int(v)
            elif field and line.isdigit():
                out[field] = int(line)
    return out


def request(path, timeout=5):
    fmt = json.dumps({'http': '%{http_code}', 'connect': '%{time_connect}', 'ttfb': '%{time_starttransfer}', 'total': '%{time_total}'})
    r = docker('exec', NAMES['api'], 'curl', '--silent', '--show-error', '--connect-timeout', '2', '--max-time', str(timeout), '-o', '/tmp/r49-body', '-D', '/tmp/r49-headers', '--write-out', fmt, 'http://' + NAMES['httpd'] + path, allow_failure=True, timeout=timeout + 10)
    try:
        timing = json.loads(r.stdout)
    except ValueError:
        timing = {'http': '000'}
    timing['curl_exit'] = r.returncode
    timing['curl_diagnostic'] = 'timeout' if r.returncode == 28 else ('connect_failed' if r.returncode == 7 else ('none' if r.returncode == 0 else 'transport_error'))
    for key in ['connect', 'ttfb', 'total']:
        if key in timing:
            timing[key] = float(timing[key])
    headers = docker('exec', NAMES['api'], 'cat', '/tmp/r49-headers', allow_failure=True).stdout.lower()
    timing['no_store'] = 'cache-control: no-store' in headers
    timing['no_referrer'] = 'referrer-policy: no-referrer' in headers
    body = docker('exec', NAMES['api'], 'cat', '/tmp/r49-body', allow_failure=True).stdout
    timing['body_bytes'] = len(body.encode())
    try:
        parsed = json.loads(body)
        timing['body_valid_json'] = True
        timing['body_fields'] = sorted(parsed) if isinstance(parsed, dict) else []
    except ValueError:
        timing['body_valid_json'] = False
    return timing


def raw_summary(raw):
    rows = []
    for line in raw.splitlines():
        try:
            record = json.loads(line)
        except ValueError:
            continue
        if not isinstance(record, dict):
            continue
        message = record.get('message', record.get('msg', ''))
        inner = None
        if isinstance(message, str):
            try:
                inner = json.loads(message)
            except ValueError:
                pass
        row = {'fields': sorted(record), 'has_msg': 'msg' in record, 'level': record.get('level'), 'level_name': record.get('level_name')}
        if isinstance(inner, dict) and 'message' in inner:
            row.update({'message_sha256': hashlib.sha256(str(inner['message']).encode()).hexdigest(), 'source_file': os.path.basename(str(inner.get('file', ''))), 'source_line': inner.get('line'), 'source_code': inner.get('code') if isinstance(inner.get('code'), int) else None})
        elif isinstance(message, str):
            row['message_sha256'] = hashlib.sha256(message.encode()).hexdigest()
        rows.append(row)
    return rows


before = protected_snapshot()
RESULT['protected_before'] = before
net_created = False
try:
    assert hashlib.sha256(ARCHIVE.read_bytes()).hexdigest() == EXPECTED_ARCHIVE
    with gzip.open(ARCHIVE, 'rb') as stream:
        while stream.read(1048576):
            pass
    RESULT['archive_sha256'] = EXPECTED_ARCHIVE
    assert len([n for n in before if n.startswith('/gstfleet-')]) == 8
    assert len([n for n in before if n.startswith('/gst-rc1-qa-')]) == 4
    assert not docker('ps', '-aq', '--filter', 'name=' + PREFIX).stdout.strip()
    docker('network', 'create', '--internal', '--label', 'gst.scope=s98-r49', NETWORK)
    net_created = True
    password = secrets.token_hex(24)
    env = {
        'MYSQL_ROOT_PASSWORD': password, 'MYSQL_ROOT_HOST': '%',
        'APP_ENV': 'testing', 'APP_DEBUG': 'false', 'APP_KEY': 'base64:' + __import__('base64').b64encode(secrets.token_bytes(32)).decode(),
        'APP_URL': 'http://r49.test', 'DB_CONNECTION': 'mysql', 'DB_HOST': NAMES['mysql'], 'DB_DATABASE': 'gst_rc1_qa', 'DB_USERNAME': 'root', 'DB_PASSWORD': password,
        'REDIS_HOST': NAMES['redis'], 'REDIS_PORT': '6379', 'REDIS_CLIENT': 'predis', 'CACHE_DRIVER': 'array', 'CACHE_STORE': 'array', 'RESPONSE_CACHE_DRIVER': 'array',
        'SESSION_DRIVER': 'array', 'QUEUE_CONNECTION': 'sync', 'MAIL_MAILER': 'array', 'LOG_CHANNEL': ARGS.log_channel, 'LOG_LEVEL': 'debug', 'VIEW_COMPILED_PATH': '/tmp', 'TELESCOPE_ENABLED': 'false',
    }
    if ARGS.log_channel == 'image-default':
        del env['LOG_CHANNEL']
    envfile = WORK / 'lab.env'
    envfile.write_text(''.join(k + '=' + v + '\n' for k, v in env.items()))
    envfile.chmod(0o600)
    cmd = launch('mysql', 'mysql:8.0-oracle', ['--memory', '768m', '--memory-swap', '768m', '--cpus', '1', '--tmpfs', '/var/lib/mysql:rw,nosuid,size=512m', '--env-file', str(envfile)])
    docker(*cmd)
    for _ in range(90):
        r = docker('logs', NAMES['mysql'], allow_failure=True)
        if 'MySQL init process done. Ready for start up.' in r.stdout + r.stderr:
            try:
                if sql('SELECT 1') == '1':
                    break
            except RuntimeError:
                pass
        time.sleep(1)
    else:
        raise RuntimeError('mysql_readiness_failed')
    with gzip.open(ARCHIVE, 'rt') as stream:
        docker('exec', '-i', NAMES['mysql'], 'sh', '-c', 'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" exec mysql -uroot', data=stream.read())
    RESULT['migrations_before'] = int(sql('SELECT COUNT(*) FROM gst_rc1_qa.migrations'))
    assert RESULT['migrations_before'] == 395
    counts = {table: int(sql('SELECT COUNT(*) FROM gst_rc1_qa.' + table)) for table in ['users', 'companies', 'drivers', 'api_credentials', 'personal_access_tokens']}
    RESULT['business_fixture_counts'] = counts
    assert not any(counts.values()), 'archive_contains_identity_data_stop_before_http'
    docker(*launch('redis', 'redis:7.4-alpine', ['--memory', '64m', '--memory-swap', '64m', '--cpus', '0.25']), 'redis-server', '--save', '', '--appendonly', 'no')
    CREATED.append(PREFIX + '-migrate')
    run = docker('run', '--rm', '--name', PREFIX + '-migrate', '--label', 'gst.scope=s98-r49', '--network', NETWORK, '--memory', '512m', '--cpus', '1', '--env-file', str(envfile), '--entrypoint', 'php', ARGS.api_image, 'artisan', 'migrate', '--force', '--no-interaction')
    (WORK / 'migration-private.log').write_text(run.stdout + run.stderr)
    RESULT['migrations_after'] = int(sql('SELECT COUNT(*) FROM gst_rc1_qa.migrations'))
    assert RESULT['migrations_after'] == 397
    apicmd = launch('api', ARGS.api_image, ['--memory', ARGS.memory, '--memory-swap', ARGS.memory, '--cpus', '1', '--pids-limit', '256', '--env-file', str(envfile), '--tmpfs', '/tmp:rw,nosuid,size=128m'], 'php')
    apicmd += ['artisan', 'octane:frankenphp', '--max-requests=1000', '--port=8000', '--host=0.0.0.0']
    if ARGS.mode == 'raw':
        apicmd += ['--log-level=debug']
    docker(*apicmd)
    docker(*launch('httpd', ARGS.proxy_image, ['--memory', '128m', '--memory-swap', '128m', '--cpus', '0.25', '--read-only', '--tmpfs', '/etc/nginx/conf.d:rw,size=4m', '--tmpfs', '/var/cache/nginx:rw,size=16m', '--tmpfs', '/var/run:rw,size=4m', '--tmpfs', '/var/log/nginx:rw,size=8m', '-e', 'NGINX_APPLICATION_HOSTNAME=' + NAMES['api']]))
    RESULT['image_ids'] = {key: inspect(name)['Image'] for key, name in NAMES.items()}
    RESULT['effective_log_channel'] = next((v.split('=', 1)[1] for v in inspect(NAMES['api'])['Config']['Env'] if v.startswith('LOG_CHANNEL=')), None)
    RESULT['network_internal'] = json.loads(docker('network', 'inspect', NETWORK).stdout)[0]['Internal']
    RESULT['published_ports'] = {key: inspect(name)['HostConfig']['PortBindings'] for key, name in NAMES.items()}
    assert all(not x for x in RESULT['published_ports'].values())
    ready = False
    for _ in range(45):
        if not inspect(NAMES['api'])['State']['Running']:
            break
        probe = request('/', 2)
        if probe['http'] == '200':
            ready = True
            break
        time.sleep(1)
    RESULT['ready'] = ready
    RESULT['before_samples_memory'] = memory()
    RESULT['before_samples_unknown'] = logs().count('unknown error')
    if not ready:
        raise RuntimeError('api_not_ready')
    scenarios = [('public', '/', '200'), ('unauthenticated', '/int/v1/fleet-ops/navigator/get-link-app', '401'), ('invalid_link', '/int/v1/fleet-ops/navigator/link-app', '403')]
    # Ten sequential repetitions of the triplet by default.
    for iteration in range(ARGS.repeats):
        for scenario, path, expected in scenarios:
            before_unknown = logs().count('unknown error')
            sample = {'iteration': iteration + 1, 'scenario': scenario, 'expected': expected, 'started_at': time.time()}
            sample.update(request(path))
            time.sleep(0.15)
            sample['unknown_before'] = before_unknown
            sample['unknown_after'] = logs().count('unknown error')
            sample['unknown_delta'] = sample['unknown_after'] - before_unknown
            sample['memory'] = memory()
            RESULT['samples'].append(sample)
            print(json.dumps({'sample': sample}), flush=True)
            if not sample['memory']['running']:
                raise RuntimeError('api_exited_during_samples')
    RESULT['summary'] = {name: dict(collections.Counter(s['http'] for s in RESULT['samples'] if s['scenario'] == name)) for name, _, _ in scenarios}
    canary = secrets.token_hex(32)
    RESULT['canary_responses'] = [request('/int/v1/fleet-ops/navigator/get-link-app?token=' + canary)['http'], request('/int/v1/fleet-ops/navigator/link-app?token=' + canary)['http']]
    time.sleep(0.3)
    proxy_logs = docker('logs', NAMES['httpd'], allow_failure=True)
    RESULT['synthetic_canary_absent_from_api_proxy_logs'] = canary not in logs() + proxy_logs.stdout + proxy_logs.stderr
    RESULT['final_memory'] = memory()
    assert all(s['http'] == s['expected'] and s['curl_exit'] == 0 for s in RESULT['samples']), 'unexpected_http_or_curl_exit'
    assert all(s['no_store'] and s['no_referrer'] for s in RESULT['samples'] if s['scenario'] != 'public') or ARGS.mode == 'baseline', 'missing_sensitive_response_headers'
    assert RESULT['synthetic_canary_absent_from_api_proxy_logs'], 'synthetic_canary_leaked_stop_no_raw_output'
    assert RESULT['canary_responses'] == ['401', '403']
    assert not RESULT['final_memory']['oom_killed']
    assert not any(RESULT['final_memory'].get('memory.events', {}).values())

finally:
    if NAMES['api'] in CREATED:
        raw = logs()
        RESULT['unknown_total'] = raw.count('unknown error')
        RESULT['raw_record_summary'] = raw_summary(raw)
        trace = docker('exec', NAMES['api'], 'cat', '/tmp/r49-exceptions.ndjson', allow_failure=True).stdout
        RESULT['exception_trace'] = [json.loads(line) for line in trace.splitlines() if line.startswith('{')]
        events = docker('exec', NAMES['api'], 'cat', '/tmp/r49-log-events.ndjson', allow_failure=True).stdout
        RESULT['log_event_trace'] = [json.loads(line) for line in events.splitlines() if line.startswith('{')]
        for key in ['api', 'httpd']:
            if key in NAMES and NAMES[key] in CREATED:
                try:
                    RESULT[key + '_final_state'] = memory() if key == 'api' else {k: inspect(NAMES[key])['State'][k] for k in ['Running', 'ExitCode', 'OOMKilled']}
                except Exception:
                    pass
    for name in reversed(CREATED):
        docker('rm', '-f', name, allow_failure=True)
    if net_created:
        docker('network', 'rm', NETWORK, allow_failure=True)
    RESULT['cleanup_containers'] = not docker('ps', '-aq', '--filter', 'label=gst.scope=s98-r49', '--filter', 'name=' + PREFIX).stdout.strip()
    RESULT['cleanup_network'] = docker('network', 'inspect', NETWORK, allow_failure=True).returncode != 0
    RESULT['protected_unchanged'] = protected_snapshot() == before
    envfile = WORK / 'lab.env'
    if envfile.exists():
        envfile.unlink()
    outfile = WORK / 'result.json'
    outfile.write_text(json.dumps(RESULT, indent=2) + '\n')
    outfile.chmod(0o600)
    print(json.dumps({'result': {k: v for k, v in RESULT.items() if k not in ['samples', 'exception_trace', 'raw_record_summary', 'protected_before']}}), flush=True)

assert RESULT['cleanup_containers'] and RESULT['cleanup_network'], 'lab_cleanup_failed'
assert RESULT['protected_unchanged'], 'protected_environment_changed'
