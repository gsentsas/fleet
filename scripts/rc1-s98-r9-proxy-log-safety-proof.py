#!/usr/bin/env python3
"""Fail closed if Docker HTTP ingress logs a raw bearer-capability URL.

This source check does not validate Plesk/front-door logs or runtime behavior.
"""
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
SENSITIVE = re.compile(r"\$(?:request|request_uri|args|query_string|http_referer)\b")
PATHS = {
    "HTTPD": ROOT / "docker" / "httpd" / "vhost.conf",
    "CONSOLE": ROOT / "console" / "nginx.conf",
}

for name, path in PATHS.items():
    conf = path.read_text(encoding="utf-8")
    fmt = re.search(r"(?ms)^\s*log_format\s+gst_fleet_safe\s+(.*?);", conf)
    assert fmt is not None, f"{name}: missing queryless log_format"
    assert "$uri" in fmt.group(1) and "$request_method" in fmt.group(1), f"{name}: missing method/path fields"
    assert SENSITIVE.search(fmt.group(1)) is None, f"{name}: request/query/referrer exposed"
    directives = re.findall(r"(?m)^\s*access_log\s+([^;]+);", conf)
    assert directives and all("gst_fleet_safe" in d.split() for d in directives), f"{name}: default combined log still present"
    print(f"S98_R9_{name}_QUERYLESS_ACCESS_LOG=PASS")

httpd = PATHS["HTTPD"].read_text(encoding="utf-8")
sensitive = re.search(
    r"(?s)location\s*=\s*/int/v1/fleet-ops/navigator/link-app\s*\{([^}]+)\}",
    httpd,
)
assert sensitive is not None, "HTTPD: sensitive route needs a location override"
assert re.search(r"error_log\s+/dev/null\s+crit\s*;", sensitive.group(1)), "HTTPD: pairing error-log could expose token"
default = re.search(r"(?s)location\s+/\s*\{([^}]+)\}", httpd)
assert default is not None, "HTTPD: default proxy location absent"
upstream = re.compile(r"proxy_pass\s+([^;]+);")
a = upstream.search(sensitive.group(1))
b = upstream.search(default.group(1))
assert a and b and a.group(1).strip() == b.group(1).strip(), "HTTPD: pairing route changes upstream"
assert "proxy_set_header Host" in sensitive.group(1), "HTTPD: pairing route missing Host forwarding"
print("S98_R9_PAIRING_PROXY_ERROR_LOG_GUARD=PASS")
print("S98_R9_PLESK_FRONT_DOOR_LOG_PRIVACY=NOT_YET_VALIDATED")
