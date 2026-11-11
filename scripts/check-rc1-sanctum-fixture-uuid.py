#!/usr/bin/env python3
"""Check synthetic administrator Sanctum fixtures reference the Fleetbase User UUID."""
from pathlib import Path
import re

scripts = Path(__file__).resolve().parent
files = sorted(scripts.glob("rc1-sanctum-*.sh"))
expected = {
    "rc1-sanctum-exempt-and-search-http-lab.sh",
    "rc1-sanctum-four-profile-iam-lab.sh",
    "rc1-sanctum-multi-resource-catalog-fail-closed-lab.sh",
    "rc1-sanctum-permission-catalog-fail-closed-candidate-lab.sh",
    "rc1-sanctum-permission-catalog-omission-lab.sh",
    "rc1-sanctum-two-profile-http-diagnostic.sh",
}
assert {p.name for p in files} == expected, "Sanctum fixture inventory changed; review required"

projection = "SELECT CONCAT('Fleetbase',CHAR(92),'Models',CHAR(92),'User'),"
for path in files:
    source = path.read_text()
    lines = source.splitlines()
    admin_rows = [i for i, line in enumerate(lines) if "'rc1-admin',SHA2(" in line]
    assert len(admin_rows) == 1, f"{path.name}: admin fixture must appear once"
    idx = admin_rows[0]
    assert idx > 0 and lines[idx - 1].strip() == projection + "uuid,", (
        f"{path.name}: admin Sanctum tokenable_id must select users.uuid"
    )
    assert "FROM users WHERE public_id='rc1-auth-user-b'" in lines[idx + 1], (
        f"{path.name}: admin fixture must select profile B"
    )
print("RC1_SANCTUM_ADMIN_UUID_FIXTURE=PASS_6_OF_6")
