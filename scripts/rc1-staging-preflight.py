#!/usr/bin/env python3
"""Fleetbase RC1 staging S1 preflight. Read-only; does not start containers.

Usage:
  python3 scripts/rc1-staging-preflight.py \
    --staging-root /srv/gst-rc1-staging \
    --production-root /opt/gst-fleet \
    --compose-file /srv/gst-rc1-staging/compose.staging.yml \
    --project-name gst-rc1-qa

Never print resolved compose: it can contain secrets.
"""
import argparse
import ipaddress
import json
import os
import pathlib
import subprocess
import sys

def fail(reason):
    print("S1_NO_GO=" + reason, file=sys.stderr)
    raise SystemExit(2)

def main():
    parser = argparse.ArgumentParser()
    for name in ("staging-root", "production-root", "compose-file", "project-name"):
        parser.add_argument("--" + name, required=True)
    args = parser.parse_args()
    root = pathlib.Path(args.staging_root).resolve(strict=True)
    prod = pathlib.Path(args.production_root).resolve(strict=True)
    compose = pathlib.Path(args.compose_file).resolve(strict=True)
    project = args.project_name
    if root == prod or prod in root.parents or root in prod.parents:
        fail("STAGING_PRODUCTION_ROOT_OVERLAP")
    if root not in compose.parents:
        fail("COMPOSE_OUTSIDE_STAGING_ROOT")
    if project in ("fleet", "fleetbase", "gstfleet", "default") or not project.startswith("gst-rc1-"):
        fail("PROJECT_NAME_NOT_ISOLATED")
    if not compose.is_file():
        fail("COMPOSE_NOT_FILE")
    env = dict(os.environ, COMPOSE_PROJECT_NAME=project)
    try:
        cmd = ["docker", "compose", "--project-directory", str(root), "-p", project, "-f", str(compose), "config", "--format", "json"]
        proc = subprocess.run(cmd, capture_output=True, text=True, env=env, timeout=35, check=False)
    except (OSError, subprocess.TimeoutExpired):
        fail("COMPOSE_CONFIG_UNAVAILABLE")
    if proc.returncode != 0:
        fail("COMPOSE_CONFIG_FAILED_REDACTED")
    try:
        data = json.loads(proc.stdout)
    except json.JSONDecodeError:
        fail("COMPOSE_CONFIG_NOT_JSON")
    if data.get("name") != project:
        fail("COMPOSE_PROJECT_NAME_MISMATCH")
    services = data.get("services", {})
    if not isinstance(services, dict) or not {"application", "database", "cache", "socket"}.issubset(services):
        fail("REQUIRED_SERVICES_MISSING")
    errors = []
    reviewed_mounts = 0
    reviewed_ports = 0
    for service, spec in services.items():
        for mount in spec.get("volumes", []):
            if isinstance(mount, str):
                errors.append("NON_STRUCTURED_MOUNT:" + service)
                continue
            if mount.get("type") == "bind":
                reviewed_mounts += 1
                source = mount.get("source", "")
                if not source or not pathlib.Path(source).is_absolute():
                    errors.append("NONABSOLUTE_BIND:" + service)
                    continue
                location = pathlib.Path(source).resolve(strict=False)
                if location != root and root not in location.parents:
                    errors.append("BIND_OUTSIDE_STAGING:" + service)
            elif mount.get("type") != "volume":
                errors.append("NON_VOLUME_MOUNT:" + service)
        for port in spec.get("ports", []):
            reviewed_ports += 1
            if not isinstance(port, dict):
                errors.append("UNSTRUCTURED_PORT:" + service)
                continue
            host = port.get("host_ip", "")
            try:
                addr = ipaddress.ip_address(host)
                if not addr.is_loopback:
                    errors.append("PUBLIC_PORT:" + service)
            except ValueError:
                errors.append("UNBOUND_HOST_IP:" + service)
            if int(port.get("published", 0) or 0) in (3306, 38000, 4200, 8000):
                errors.append("DEFAULT_PORT_COLLISION:" + service)
        image = spec.get("image", "")
        if image and ("latest" in image or "@sha256:" not in image):
            errors.append("IMAGE_NOT_DIGEST_PINNED:" + service)
        environment = spec.get("environment", {})
        if isinstance(environment, dict) and str(environment.get("MYSQL_ALLOW_EMPTY_PASSWORD", "")).lower() in ("yes", "true", "1"):
            errors.append("MYSQL_EMPTY_PASSWORD:" + service)
    if reviewed_mounts == 0:
        errors.append("NO_STAGING_BIND_MOUNT_PROOF")
    # Named volumes are allowed only when compose project name is unique;
    # external volumes are forbidden because they can point to production.
    for name, vol in (data.get("volumes") or {}).items():
        if vol.get("external"):
            errors.append("EXTERNAL_VOLUME:" + name)
    print("S1_STAGING_ROOT_SEPARATE=PASS")
    print("S1_COMPOSE_PROJECT=" + project)
    print("S1_REVIEWED_BINDS=" + str(reviewed_mounts))
    print("S1_REVIEWED_PUBLISHED_PORTS=" + str(reviewed_ports))
    if errors:
        for code in sorted(set(errors)):
            print("S1_FAIL=" + code)
        fail("COMPOSE_ISOLATION_NOT_PROVEN")
    print("S1_STATIC_COMPOSE_ISOLATION=PASS")
    print("S1_RUNTIME_HOST_VOLUME_PROOF=NOT_RUN")
    print("S2_BACKUP_RESTORE=NOT_RUN")
    print("PRODUCTION_DECISION=NO_GO")

if __name__ == "__main__":
    main()
