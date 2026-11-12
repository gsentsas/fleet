#!/usr/bin/env python3
"""Generate a SHADOW Plesk privacy configuration, never install or reload."""
import argparse
import hashlib
from pathlib import Path
import re
import sys

DOMAINS = (
    "fleet.globalsentransport.fr",
    "api-fleet.globalsentransport.fr",
    "ws-fleet.globalsentransport.fr",
)
ROUTE = "/int/v1/fleet-ops/navigator/link-app"
BASE = Path("/usr/local/psa/admin/conf/templates/default/domain/nginxDomainVirtualHost.php")
CUSTOM = Path("/usr/local/psa/admin/conf/templates/custom/domain/nginxDomainVirtualHost.php")
VHOSTS = Path("/var/www/vhosts/system")
EXPECTED_TEMPLATE_SHA = "949c5d2090dec908774ff39271de15b4907d68561ffb95a809494b425ce24233"

def fail(message):
    raise RuntimeError("S98_R12_FAIL_CLOSED: " + message)

def digest(data):
    return hashlib.sha256(data).hexdigest()

def write_new(root, name, content):
    output = root / name
    output.parent.mkdir(parents=True, exist_ok=True)
    if output.exists() or output.is_symlink():
        fail("Shadow output already exists")
    output.write_text(content, encoding="utf-8")
    output.chmod(0o600)

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", required=True)
    args = parser.parse_args()
    out = Path(args.out).resolve()
    if not out.is_relative_to(Path("/tmp")) or out == Path("/tmp") or not out.is_dir():
        fail("Output must be an existing directory beneath /tmp")
    if any(out.iterdir()):
        fail("Output directory must be empty")
    if CUSTOM.exists() or CUSTOM.is_symlink():
        fail("Existing Plesk custom template: manual review required")
    if not BASE.is_file():
        fail("Missing default Plesk template")
    raw = BASE.read_bytes()
    if digest(raw) != EXPECTED_TEMPLATE_SHA:
        fail("Plesk default template SHA drift")
    php = raw.decode("utf-8")
    options = "[" + ", ".join("'" + d + "'" for d in DOMAINS) + "]"
    access = [line for line in php.splitlines(keepends=True)
              if line.lstrip().startswith("access_log <?= $VAR->quote(")]
    if len(access) != 1 or not access[0].rstrip().endswith("?>;"):
        fail("Unexpected Plesk access_log syntax")
    original = access[0]
    amended = original.replace(
        "?>;",
        "?><?= in_array($VAR->domain->targetName, "
        + options + ", true) ? ' gst_fleet_safe' : '' ?>;",
    )
    if php.count(original) != 1 or amended == original:
        fail("Access log replacement ambiguity")
    php = php.replace(original, amended, 1)
    redirect = (
        "        location / {\n"
        "            return 301 https://$host$request_uri;\n"
        "        }"
    )
    if php.count(redirect) != 1:
        fail("Unexpected Plesk HTTP redirect syntax")
    deny_plaintext = (
        "<?php if (in_array($VAR->domain->targetName, " + options + ", true)): ?>\n"
        "        location = " + ROUTE + " {\n"
        "            return 403;\n"
        "        }\n"
        "<?php endif; ?>\n\n"
    )
    php = php.replace(redirect, deny_plaintext + redirect, 1)
    write_new(out, Path("templates/custom/domain/nginxDomainVirtualHost.php"), php)
    log_format = (
        "# Nginx http context; selected Fleetbase vhosts only.\n"
        "log_format gst_fleet_safe "
        "'$remote_addr - [$time_local] \"$request_method $uri $server_protocol\" '\n"
        "                          '$status $body_bytes_sent rt=$request_time';\n"
    )
    write_new(out, Path("conf.d/aa900_gst_fleet_safe_logging.conf"), log_format)
    report = [
        "S98_R12_READONLY_SHADOW=PASS",
        "PLESK_BASE_SHA256=" + EXPECTED_TEMPLATE_SHA,
        "TARGET_DOMAIN_COUNT=3",
        "S98_R12_HTTP_TOKEN_DENY_TEMPLATE=PASS_SOURCE",
        "S98_R12_ACTIVE_CONFIG=UNCHANGED",
        "S98_R12_EFFECTIVE_PLESK_LOG_REDACTION=NOT_PROVEN",
    ]
    for domain in DOMAINS:
        path = VHOSTS / domain / "conf/vhost_nginx.conf"
        if not path.is_file() or path.is_symlink():
            fail("Missing or linked proxy config: " + domain)
        body = path.read_text(encoding="utf-8")
        found = list(re.finditer(r"(?ms)^location /\s*\{\n.*?^\}\s*$", body))
        if len(found) != 1 or body.count("location / {") != 1:
            fail("Unrecognized proxy configuration: " + domain)
        match = found[0]
        block = match.group(0)
        if block.count("{") != 1 or block.count("}") != 1:
            fail("Nested proxy rules may be unsafe: " + domain)
        if "allow 127.0.0.1;" not in block or "deny all;" not in block:
            fail("Expected access restrictions absent: " + domain)
        if "proxy_pass " not in block or "error_log " in block:
            fail("Unrecognized proxy or logging rules: " + domain)
        exact = block.replace(
            "location / {",
            "location = " + ROUTE + " {\n    error_log /dev/null crit;",
            1,
        )
        restored = exact.replace(
            "location = " + ROUTE + " {\n    error_log /dev/null crit;",
            "location / {",
            1,
        )
        if restored != block:
            fail("Proxy restrictions changed in exact route: " + domain)
        patched = body[:match.start()] + exact + "\n\n" + body[match.start():]
        write_new(out, Path("vhosts") / domain / "vhost_nginx.conf", patched)
        report.append("S98_R12_" + domain.replace(".", "_").replace("-", "_")
                      + "_ACL_AND_UPSTREAM=UNCHANGED")
        report.append("VHOST_BASE_SHA256=" + digest(path.read_bytes()))
    write_new(out, Path("report.txt"), "\n".join(report) + "\n")
    for line in report:
        print(line)

if __name__ == "__main__":
    try:
        main()
    except (OSError, UnicodeError, RuntimeError) as exc:
        print(exc, file=sys.stderr)
        sys.exit(1)
