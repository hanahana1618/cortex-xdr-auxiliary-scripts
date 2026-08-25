#!/usr/bin/env bash
#
# verify-cortex-xdr-install.sh
#
# Post-install health check for the Palo Alto Networks Cortex XDR Linux
# agent. Checks the systemd service, running process, install directory,
# agent version (via cytool, if present), recent logs, kernel-vs-user-mode
# operation, tenant registration signals, clock sync, distribution-server
# reachability, and hostname stability since the agent started.
#
# The extra checks beyond basic "is it running" exist because a running
# service doesn't guarantee the tenant console actually sees the endpoint:
# the kernel module can silently fail to load on uncertified kernels
# (agent falls back to degraded user-space/async mode), and a hostname
# change after initial registration can leave a stale/duplicate entry in
# the console instead of updating the existing one.
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

# 6. Kernel mode vs. user-space/async mode
#    A running service does not mean the kernel driver ("Cortex XDR core")
#    actually loaded. On kernels PANW hasn't certified (e.g. distro-patched
#    kernels like Pop!_OS's), the agent silently falls back to degraded
#    user-space/async mode instead of failing loudly.
echo
echo "-- Kernel module / operation mode --"
KMOD_HIT="$(lsmod 2>/dev/null | grep -iE '^(pan_|cortex|traps|kproc)' | head -n1)"
if [[ -n "$KMOD_HIT" ]]; then
  echo "[PASS] Cortex XDR kernel module appears loaded: $KMOD_HIT"
  PASS=$((PASS + 1))
else
  echo "[WARN] No Cortex XDR kernel module found in 'lsmod' -- agent is likely running in"
  echo "       user-space/asynchronous mode (reduced protection capability), commonly caused"
  echo "       by running an uncertified/distro-patched kernel: $(uname -r)"
fi

if command -v dmesg >/dev/null 2>&1; then
  DMESG_HITS="$(dmesg 2>/dev/null | grep -iE 'cortex|traps|pan_km|kproc' | tail -10)"
  if [[ -n "$DMESG_HITS" ]]; then
    echo "  dmesg (kernel driver load attempts):"
    echo "$DMESG_HITS" | sed 's/^/    /'
  fi
fi

JOURNAL_MODE_HITS="$(journalctl -u traps_pmd.service -b --no-pager 2>/dev/null | grep -iE 'kernel mode|user mode|user space|async|kproc|module' | tail -10)"
if [[ -n "$JOURNAL_MODE_HITS" ]]; then
  echo "  Related traps_pmd.service log lines (this boot):"
  echo "$JOURNAL_MODE_HITS" | sed 's/^/    /'
fi

# 7. Tenant registration / pairing signals
#    Doesn't prove registration succeeded (that's authoritative in the
#    console + cytool's own status field, checked above), but surfaces the
#    log lines most likely to explain a missing/stale console entry.
echo
echo "-- Tenant registration / pairing signals --"
REG_HITS="$(journalctl -u traps_pmd.service --no-pager 2>/dev/null | grep -iE 'regist|pair|connect|error|fail' | tail -20)"
if [[ -n "$REG_HITS" ]]; then
  echo "$REG_HITS" | sed 's/^/  /'
else
  echo "[INFO] No registration/pairing/connection/error lines found in traps_pmd.service logs"
fi

# 8. System clock sync (cert validation and registration can fail silently on clock skew)
echo
echo "-- Clock sync --"
if command -v timedatectl >/dev/null 2>&1; then
  if timedatectl show -p NTPSynchronized --value 2>/dev/null | grep -q "^yes$"; then
    echo "[PASS] System clock is NTP-synchronized"
    PASS=$((PASS + 1))
  else
    echo "[WARN] System clock is NOT reported as NTP-synchronized -- clock skew can silently break TLS/registration"
  fi
else
  echo "[SKIP] timedatectl not available"
fi

# 9. Reachability to the distribution/management server
echo
echo "-- Distribution/management server reachability --"
DIST_SERVER="${CORTEX_DISTRIBUTION_SERVER:-https://distributions.traps.paloaltonetworks.com/}"
if command -v curl >/dev/null 2>&1; then
  if curl -sS --max-time 5 -o /dev/null "$DIST_SERVER"; then
    echo "[PASS] Reachable over HTTPS: $DIST_SERVER"
    PASS=$((PASS + 1))
  else
    echo "[WARN] Could not reach $DIST_SERVER over HTTPS (check outbound TCP/443 / proxy / DNS)"
  fi
  echo "       (set \$CORTEX_DISTRIBUTION_SERVER to check your actual tenant's server instead of the default)"
else
  echo "[SKIP] curl not available"
fi

# 10. Hostname stability since the agent started
#     A hostname change after initial registration can leave a stale/
#     duplicate entry in the console under the old name instead of
#     updating the existing one.
echo
echo "-- Hostname stability --"
CURRENT_HOSTNAME="$(hostname)"
LOGGED_HOSTNAMES="$(journalctl -u traps_pmd.service --no-pager 2>/dev/null | grep -v '^-- ' | awk '{print $4}' | sort -u)"
LOGGED_COUNT="$(echo "$LOGGED_HOSTNAMES" | grep -c .)"
if [[ "$LOGGED_COUNT" -gt 1 ]]; then
  echo "[WARN] traps_pmd.service logs show more than one hostname since the agent started:"
  echo "$LOGGED_HOSTNAMES" | sed 's/^/         /'
  echo "       Current hostname: $CURRENT_HOSTNAME"
  echo "       If registration happened under an earlier name, check the console for a stale/duplicate entry there."
elif [[ "$LOGGED_COUNT" -eq 1 ]]; then
  echo "[PASS] Hostname has been stable ($CURRENT_HOSTNAME) for all logged traps_pmd.service activity"
  PASS=$((PASS + 1))
else
  echo "[SKIP] No traps_pmd.service log history found to check hostname stability against"
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
