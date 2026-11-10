#!/usr/bin/env bash
# GST Fleetbase RC1: READ-ONLY private staging capacity gate.
# Never starts containers, connects to production DBs, or reads backup secrets.
set -euo pipefail

fail=0
require() {
  local label="$1" condition="$2" observed="$3"
  if [ "$condition" = 1 ]; then
    printf '%s=PASS (%s)\n' "$label" "$observed"
  else
    printf '%s=NO_GO (%s)\n' "$label" "$observed"
    fail=1
  fi
}

case "$(uname -s)" in
  Linux|Darwin) ;;
  *) echo "STOP=UNSUPPORTED_HOST"; exit 2 ;;
esac

disk_kib=$(df -Pk / | awk 'NR==2 {print $4}')
disk_pct=$(df -Pk / | awk 'NR==2 {gsub(/%/,"",$5); print $5}')
require "RC1_FREE_DISK_AT_LEAST_25_GIB" "$([ "$disk_kib" -ge 26214400 ] && echo 1 || echo 0)" "free_kib=$disk_kib"
require "RC1_DISK_USAGE_AT_MOST_85_PERCENT" "$([ "$disk_pct" -le 85 ] && echo 1 || echo 0)" "used_pct=$disk_pct"

if [ "$(uname -s)" = Linux ]; then
  available_kib=$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)
  require "RC1_HOST_AVAILABLE_RAM_AT_LEAST_8_GIB" "$([ "$available_kib" -ge 8388608 ] && echo 1 || echo 0)" "available_kib=$available_kib"
else
  # macOS host memory pressure is not equivalent to total installed RAM.
  # Require an independent memory-pressure check before approving staging.
  echo "RC1_HOST_AVAILABLE_RAM_AT_LEAST_8_GIB=NO_GO (macOS_memory_pressure_not_attested)"
  fail=1
fi

if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
  echo "RC1_DOCKER_ENGINE=NO_GO (unavailable)"
  fail=1
else
  memory=$(docker info --format '{{.MemTotal}}' 2>/dev/null || printf 0)
  require "RC1_DOCKER_MEMORY_AT_LEAST_8_GIB" "$([ "$memory" -ge 8589934592 ] && echo 1 || echo 0)" "docker_memory_bytes=$memory"
  active=$(docker ps --format '{{.Names}}' | grep -c '^gstfleet-' || true)
  require "RC1_NO_PRODUCTION_GSTFLEET_CONTAINERS" "$([ "$active" -eq 0 ] && echo 1 || echo 0)" "production_named_containers=$active"
  # A private staging host must not simultaneously host production fleet.
  # Operator must separately verify external integrations are disabled.
fi

echo "RC1_EXTERNAL_EGRESS_ISOLATION=REQUIRES_MANUAL_ATTESTATION"
echo "RC1_BACKUP_DATA_LOCALITY=REQUIRES_MANUAL_ATTESTATION"
echo "RC1_RUNTIME_ROLLBACK=NOT_TESTED"
if [ "$fail" -ne 0 ]; then
  echo "RC1_PRIVATE_STAGING_CAPACITY=NO_GO"
  exit 2
fi
echo "RC1_PRIVATE_STAGING_CAPACITY=CONDITIONAL_PASS_MANUAL_ATTESTATION_PENDING"
