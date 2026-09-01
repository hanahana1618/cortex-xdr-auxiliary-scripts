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
#   sudo ./verify-cortex-xdr-install.sh [--fix-kernel-lock]
#
#   --fix-kernel-lock   Opt-in only. If (and only if) cytool reports the
#                        specific "Kernel Module Locked" condition (caused
#                        by repeated ungraceful shutdowns, per PANW KB
#                        article kA14u000000CqdACAS), run their documented
#                        recovery sequence. This briefly DISABLES agent
#                        protection (cytool runtime stop/start) -- it is
#                        NOT run by default, and does nothing if that exact
#                        condition isn't detected. It will NOT fix a
#                        genuinely unsupported/incompatible kernel (a
#                        prebuilt signed kernel module can't be forced onto
#                        a kernel it wasn't built for) -- there is no local
#                        command for that. If the module is simply absent
#                        because the running kernel isn't PANW-certified,
#                        your only real options are (a) run a certified
#                        kernel, or (b) accept User Space/eBPF mode as the
#                        intended operation mode, set via the endpoint's
#                        Agent Settings Profile in the Cortex XDR console
#                        -- not a local flag.
#
# Exit codes:
#   0 - no hard failures (may still have [WARN]s worth reading -- e.g. a
#       hostname change can explain an agent that's running but not
#       showing correctly in the tenant console, even though every hard
#       PASS/FAIL check passed)
#   1 - agent not found / not running / a hard check failed
#
set -uo pipefail

# Bold/red only when writing to an actual terminal, so piped/logged output
# doesn't fill up with raw escape codes.
if [[ -t 1 ]]; then
  BOLD=$'\033[1m'
  RED=$'\033[31m'
  RESET=$'\033[0m'
else
  BOLD=''
  RED=''
  RESET=''
fi

FIX_KERNEL_LOCK=0
for arg in "$@"; do
  case "$arg" in
    --fix-kernel-lock) FIX_KERNEL_LOCK=1 ;;
    *) echo "Unknown argument: $arg" >&2; exit 1 ;;
  esac
done

PASS=0
FAIL=0
WARN=0

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
  echo "-- cytool status --"
  CYTOOL_STATUS_OUT="$("$CYTOOL" status 2>&1)"
  echo "$CYTOOL_STATUS_OUT" | sed 's/^/  /'
  echo
  echo "-- cytool runtimequery --"
  "$CYTOOL" runtimequery 2>&1 | sed 's/^/  /' || true
  check "cytool reports agent status" bash -c "'$CYTOOL' runtimequery >/dev/null 2>&1"

  # 4b. Tenant check-in evidence.
  #     `cytool status` prints a "Last Successful Check-In time" field on
  #     real installs -- this is the actual, confirmed-reliable signal that
  #     the agent has successfully talked to the tenant. (An earlier
  #     version of this check instead grepped for a "distribution ID" line
  #     in cytool's output -- real-world testing showed cytool doesn't
  #     print one at all on a working, checked-in agent, so that check
  #     produced a false [FAIL]. Check-in time is what's actually present
  #     and actually means something; use it instead.)
  echo
  echo "-- Tenant check-in --"
  CHECKIN_LINE="$(echo "$CYTOOL_STATUS_OUT" | grep -i "Successful Check-In time (UTC)" | head -n1)"
  CHECKIN_VALUE="$(echo "$CHECKIN_LINE" | sed -E 's/^[^:]*\(UTC\):[[:space:]]*//')"
  CHECKIN_CHECKED_VIA_CYTOOL=1
  if [[ -z "$CHECKIN_LINE" ]]; then
    echo "${BOLD}${RED}[FAIL] No 'Last Successful Check-In' field found in cytool status output.${RESET}"
    echo "${BOLD}${RED}       Cannot confirm this agent has ever reached the tenant -- treating this${RESET}"
    echo "${BOLD}${RED}       installation as UNSUCCESSFUL. (cytool's output format may differ by${RESET}"
    echo "${BOLD}${RED}       agent version -- check the raw output above if this looks wrong.)${RESET}"
    FAIL=$((FAIL + 1))
  elif [[ -z "$CHECKIN_VALUE" || "$CHECKIN_VALUE" =~ ^[Nn]ever$ ]]; then
    echo "${BOLD}${RED}[FAIL] Last Successful Check-In is empty/'Never' -- this agent has NOT${RESET}"
    echo "${BOLD}${RED}       registered/checked in with the tenant. Installation is UNSUCCESSFUL.${RESET}"
    FAIL=$((FAIL + 1))
  else
    echo "[PASS] Last successful check-in: $CHECKIN_VALUE"
    PASS=$((PASS + 1))
  fi
else
  echo "[SKIP] cytool binary not found under /opt/traps (path may differ by version, or this"
  echo "       script isn't running as root -- /opt/traps is only traversable by root, so a"
  echo "       non-root run cannot tell 'genuinely missing' apart from 'permission blocked')."
  echo "[SKIP] Cannot confirm tenant check-in without cytool -- re-run with sudo to check it."
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
    WARN=$((WARN + 1))
  fi
else
  echo "[SKIP] Log directory $LOGDIR not found"
fi

# 6. Kernel mode vs. user-space/async mode
#    A running service does not mean the kernel driver ("Cortex XDR core")
#    actually loaded. On kernels PANW hasn't certified (e.g. distro-patched
#    kernels like Pop!_OS's), the agent silently falls back to degraded
#    user-space/async mode instead of failing loudly. Treated as a hard
#    FAIL, not a warning: an agent stuck in user-space/async mode is not
#    correctly/fully installed, even while the service reports "active".
echo
echo "-- Kernel module / operation mode --"
KMOD_HIT="$(lsmod 2>/dev/null | grep -iE '^(pan_|cortex|traps|kproc)' | head -n1)"
if [[ -n "$KMOD_HIT" ]]; then
  echo "[PASS] Cortex XDR kernel module appears loaded: $KMOD_HIT"
  PASS=$((PASS + 1))
else
  echo "[FAIL] No Cortex XDR kernel module found in 'lsmod' -- agent is running in degraded"
  echo "       user-space/asynchronous mode, not full kernel mode. Commonly caused by running"
  echo "       an uncertified/distro-patched kernel: $(uname -r)"
  FAIL=$((FAIL + 1))
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

# 6b. "Kernel Module Locked" -- a specific, documented, RECOVERABLE
#     condition (PANW KB kA14u000000CqdACAS), distinct from a genuinely
#     unsupported kernel. Caused by repeated ungraceful shutdowns tripping
#     a lockout; recovery clears /etc/traps/km/.load_lock. Only touches
#     the running agent if --fix-kernel-lock was passed AND this exact
#     condition is detected -- never automatically.
if [[ -n "${CYTOOL:-}" && -x "${CYTOOL:-}" ]]; then
  CYTOOL_STATUS="$("$CYTOOL" status 2>&1)"
  if echo "$CYTOOL_STATUS" | grep -iq "Kernel Module Locked"; then
    echo "[FAIL] cytool reports 'Kernel Module Locked' -- a specific, recoverable condition"
    echo "       (repeated ungraceful shutdowns tripped a lockout), NOT the same thing as an"
    echo "       unsupported kernel. Documented recovery: PANW KB kA14u000000CqdACAS."
    FAIL=$((FAIL + 1))
    if [[ "$FIX_KERNEL_LOCK" -eq 1 ]]; then
      echo "       --fix-kernel-lock passed -- running the documented recovery sequence:"
      echo "       (this briefly disables agent protection)"
      set -x
      "$CYTOOL" runtime stop
      rm -f "/etc/traps/km/.load_lock"
      "$CYTOOL" runtime start
      "$CYTOOL" status
      set +x
      echo "       Recovery sequence complete. Re-run this script (without the flag) to confirm."
    else
      echo "       Re-run with --fix-kernel-lock to apply it (disables protection briefly)."
    fi
  else
    echo "[INFO] cytool status does not report 'Kernel Module Locked' -- if the kernel module is"
    echo "       still absent above, this is not a lock-file issue and that recovery won't help."
    echo "       See the header comment for the two real remedies (certified kernel, or an"
    echo "       explicit User Space mode policy set in the Cortex XDR console)."
  fi
elif [[ "$FIX_KERNEL_LOCK" -eq 1 ]]; then
  echo "[SKIP] --fix-kernel-lock passed but cytool wasn't found -- nothing to run."
fi

# 7. Tenant registration / pairing signals (journalctl-based, supplementary)
#    IMPORTANT: real-world testing showed a working, successfully
#    checked-in agent can have ZERO registration/pairing hits in
#    traps_pmd.service's journald logs -- that data apparently isn't
#    logged there on all agent versions. So when cytool's own "Last
#    Successful Check-In" field was available above (the authoritative
#    signal), this section is INFORMATIONAL ONLY and does not affect
#    PASS/FAIL, to avoid the false failure we hit before. It only counts
#    as a hard signal when cytool wasn't available and this is the only
#    evidence we have.
echo
echo "-- Tenant registration / pairing signals (journalctl, supplementary) --"
REG_HITS="$(journalctl -u traps_pmd.service --no-pager 2>/dev/null | grep -iE 'regist|pair|connect|error|fail' | tail -20)"
REG_ERROR_HITS="$(echo "$REG_HITS" | grep -iE 'error|fail')"
if [[ -n "$REG_ERROR_HITS" ]]; then
  echo "[INFO] Error/failure lines found in traps_pmd.service logs (informational, see cytool"
  echo "       check-in result above for the authoritative signal):"
  echo "$REG_ERROR_HITS" | sed 's/^/  /'
  if [[ "${CHECKIN_CHECKED_VIA_CYTOOL:-0}" -ne 1 ]]; then
    FAIL=$((FAIL + 1))
  fi
elif [[ -n "$REG_HITS" ]]; then
  echo "[INFO] Found registration/pairing/connection activity in traps_pmd.service logs, no errors:"
  echo "$REG_HITS" | sed 's/^/  /'
  if [[ "${CHECKIN_CHECKED_VIA_CYTOOL:-0}" -ne 1 ]]; then
    PASS=$((PASS + 1))
  fi
else
  if [[ "${CHECKIN_CHECKED_VIA_CYTOOL:-0}" -eq 1 ]]; then
    echo "[INFO] No registration/pairing/connection/error lines in traps_pmd.service logs -- not"
    echo "       unusual; this agent version apparently doesn't log check-ins there. See the"
    echo "       cytool check-in result above for the authoritative signal instead."
  else
    echo "[FAIL] No registration/pairing/connection/error lines found anywhere in traps_pmd.service"
    echo "       logs, and cytool wasn't available to check authoritatively (see above -- likely"
    echo "       needs sudo). Re-run with sudo before trusting this result."
    FAIL=$((FAIL + 1))
  fi
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
    WARN=$((WARN + 1))
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
    WARN=$((WARN + 1))
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
  WARN=$((WARN + 1))
elif [[ "$LOGGED_COUNT" -eq 1 ]]; then
  echo "[PASS] Hostname has been stable ($CURRENT_HOSTNAME) for all logged traps_pmd.service activity"
  PASS=$((PASS + 1))
else
  echo "[SKIP] No traps_pmd.service log history found to check hostname stability against"
fi

echo
echo "== Summary: $PASS passed, $WARN warned, $FAIL failed =="

if [[ "$FAIL" -gt 0 ]]; then
  echo "Cortex XDR agent verification found problems - see [FAIL] lines above."
  exit 1
elif [[ "$WARN" -gt 0 ]]; then
  echo "No hard failures, but $WARN warning(s) above are worth resolving -- e.g. a kernel-module or"
  echo "hostname-stability warning can explain an agent that's running but not showing correctly in"
  echo "the tenant console, even though every hard check passed."
  exit 0
else
  echo "Cortex XDR agent looks installed and healthy, with no warnings."
  exit 0
fi
