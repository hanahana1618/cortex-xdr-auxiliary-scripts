#!/usr/bin/env bash
#
# verify-cortex-xdr-install.sh
#
# Post-install health check for the Palo Alto Networks Cortex XDR Linux
# agent. Checks the systemd service, running process, install directory,
# agent version (via cytool, if present), and recent logs.
#
# Usage:
#   sudo ./verify-cortex-xdr-install.sh
#
# Exit codes:
#   0 - agent appears installed and running
#   1 - agent not found / not running / checks failed
#
set -uo pipefail

PASS=0
FAIL=0

check() {
  local desc="$1"
  shift
  if "$@" >/tmp/cortex_verify_out.$$ 2>&1; then
    echo "[PASS] $desc"
    PASS=$((PASS + 1))
  else
    echo "[FAIL] $desc"
    sed 's/^/       /' /tmp/cortex_verify_out.$$
    FAIL=$((FAIL + 1))
  fi
  rm -f /tmp/cortex_verify_out.$$
}

echo "== Cortex XDR install verification =="
echo "Host: $(hostname)   Date: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo

# 1. Install directory present
check "Install directory /opt/traps exists" test -d /opt/traps

# 2. systemd service exists and is active
if systemctl list-unit-files 2>/dev/null | grep -q '^traps_pmd\.service'; then
  check "traps_pmd.service is active" bash -c "systemctl is-active --quiet traps_pmd.service"
  check "traps_pmd.service is enabled" bash -c "systemctl is-enabled --quiet traps_pmd.service"
else
  echo "[FAIL] traps_pmd.service unit not found"
  FAIL=$((FAIL + 1))
fi

# 3. Agent process actually running
check "Cortex XDR process running (traps_pmd)" bash -c "pgrep -f traps_pmd >/dev/null"

# 4. cytool status / version, if the binary is present
CYTOOL="$(find /opt/traps -maxdepth 3 -iname cytool 2>/dev/null | head -n1)"
if [[ -n "$CYTOOL" && -x "$CYTOOL" ]]; then
  echo
  echo "-- cytool runtimequery --"
  "$CYTOOL" runtimequery 2>&1 | sed 's/^/  /' || true
  check "cytool reports agent status" bash -c "'$CYTOOL' runtimequery >/dev/null 2>&1"
else
  echo "[SKIP] cytool binary not found under /opt/traps (path may differ by version)"
fi

# 5. Recent agent log activity (last 5 minutes)
LOGDIR="/var/log/traps"
if [[ -d "$LOGDIR" ]]; then
  RECENT=$(find "$LOGDIR" -type f -mmin -5 2>/dev/null | wc -l)
  if [[ "$RECENT" -gt 0 ]]; then
    echo "[PASS] Recent log activity in $LOGDIR (last 5 min)"
    PASS=$((PASS + 1))
  else
    echo "[WARN] No log activity in $LOGDIR in the last 5 minutes (may be normal if idle)"
  fi
else
  echo "[SKIP] Log directory $LOGDIR not found"
fi

echo
echo "== Summary: $PASS passed, $FAIL failed =="

if [[ "$FAIL" -eq 0 ]]; then
  echo "Cortex XDR agent looks installed and healthy."
  exit 0
else
  echo "Cortex XDR agent verification found problems - see [FAIL] lines above."
  exit 1
fi
