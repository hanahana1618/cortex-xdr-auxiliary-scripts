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
# Output ends with a one-line verdict meant to be read on its own, e.g.
# "Cortex XDR is functioning but NOT at the kernel level" or "Cortex XDR
# is NOT functioning -- here are the most important items to fix", so you
# know what action (if any) is needed before reading the full report.
#
# Exit codes:
#   0 - functioning (fully at kernel level, or degraded-but-registered
#       user-space mode -- read the verdict line to tell which)
#   1 - not functioning, or status couldn't be fully verified (re-run
#       with sudo)
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
FAIL_ITEMS=()

# State tracked specifically to build the one-line verdict at the end --
# separate from the PASS/FAIL/WARN counts, because "how many checks
# failed" isn't the same question as "is this thing actually working".
IS_ROOT=0
[[ "$(id -u)" -eq 0 ]] && IS_ROOT=1
SERVICE_OK=0
PROCESS_OK=0
CHECKIN_STATUS="unknown"   # unknown | pass | fail
KERNEL_MODULE_OK=0

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
    FAIL_ITEMS+=("$desc")
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
  if systemctl is-active --quiet traps_pmd.service; then
    echo "[PASS] traps_pmd.service is active"
    PASS=$((PASS + 1))
    SERVICE_OK=1
  else
    echo "[FAIL] traps_pmd.service is active"
    FAIL=$((FAIL + 1))
    FAIL_ITEMS+=("traps_pmd.service is not active")
  fi
  check "traps_pmd.service is enabled" bash -c "systemctl is-enabled --quiet traps_pmd.service"
else
  echo "[FAIL] traps_pmd.service unit not found"
  FAIL=$((FAIL + 1))
  FAIL_ITEMS+=("traps_pmd.service unit not found (agent not installed?)")
fi

# 3. Agent process actually running
if pgrep -f traps_pmd >/dev/null 2>&1; then
  echo "[PASS] Cortex XDR process running (traps_pmd)"
  PASS=$((PASS + 1))
  PROCESS_OK=1
else
  echo "[FAIL] Cortex XDR process running (traps_pmd)"
  FAIL=$((FAIL + 1))
  FAIL_ITEMS+=("no traps_pmd process running")
fi

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
    FAIL_ITEMS+=("no 'Last Successful Check-In' field in cytool output")
    CHECKIN_STATUS="fail"
  elif [[ -z "$CHECKIN_VALUE" || "$CHECKIN_VALUE" =~ ^[Nn]ever$ ]]; then
    echo "${BOLD}${RED}[FAIL] Last Successful Check-In is empty/'Never' -- this agent has NOT${RESET}"
    echo "${BOLD}${RED}       registered/checked in with the tenant. Installation is UNSUCCESSFUL.${RESET}"
    FAIL=$((FAIL + 1))
    FAIL_ITEMS+=("agent has never checked in with the tenant")
    CHECKIN_STATUS="fail"
  else
    echo "[PASS] Last successful check-in: $CHECKIN_VALUE"
    PASS=$((PASS + 1))
    CHECKIN_STATUS="pass"
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
  KERNEL_MODULE_OK=1
else
  echo "[FAIL] No Cortex XDR kernel module found in 'lsmod' -- agent is running in degraded"
  echo "       user-space/asynchronous mode, not full kernel mode. Commonly caused by running"
  echo "       an uncertified/distro-patched kernel: $(uname -r)"
  FAIL=$((FAIL + 1))
  FAIL_ITEMS+=("kernel module not loaded (degraded/user-space mode, kernel $(uname -r))")
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
    FAIL_ITEMS+=("cytool reports 'Kernel Module Locked' -- recoverable, see --fix-kernel-lock")
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
    FAIL_ITEMS+=("no registration evidence found, and cytool unavailable to confirm (try sudo)")
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
echo

# ---------------------------------------------------------------------------
# One-line verdict, meant to be read on its own before the rest of the
# report. Priority order matters: "is it running at all" beats "is it
# registered" beats "is it at full kernel-mode capability" -- each tier
# below assumes everything above it is already true.
# ---------------------------------------------------------------------------
EXIT_CODE=0
if [[ "$IS_ROOT" -ne 1 && "$CHECKIN_STATUS" == "unknown" ]]; then
  echo "${BOLD}❓ CANNOT FULLY VERIFY: re-run this script with sudo for a definitive answer.${RESET}"
  echo "   (cytool and several other checks need root -- results above are incomplete without it.)"
  EXIT_CODE=1
elif [[ "$SERVICE_OK" -ne 1 || "$PROCESS_OK" -ne 1 ]]; then
  echo "${BOLD}${RED}❌ Cortex XDR is NOT functioning -- the agent isn't running on this machine.${RESET}"
  echo "   Most important items to fix:"
  for item in "${FAIL_ITEMS[@]}"; do echo "     - $item"; done
  EXIT_CODE=1
elif [[ "$CHECKIN_STATUS" == "fail" ]]; then
  echo "${BOLD}${RED}❌ Cortex XDR is NOT functioning -- it's running locally but has never${RESET}"
  echo "${BOLD}${RED}   registered/checked in with your tenant.${RESET}"
  echo "   Most important items to fix:"
  for item in "${FAIL_ITEMS[@]}"; do echo "     - $item"; done
  EXIT_CODE=1
elif [[ "$KERNEL_MODULE_OK" -ne 1 ]]; then
  echo "${BOLD}⚠️  Cortex XDR is functioning, but NOT at the kernel level${RESET} (degraded/user-space mode)."
  echo "   Registered and checked in with the tenant, but Anti-Malware/DSE and similar"
  echo "   kernel-dependent capabilities are unavailable. See 'Kernel module / operation mode'"
  echo "   above -- likely fix is enabling BPF fallback in this endpoint's Agent Settings"
  echo "   Profile in the console, not reinstalling or changing distribution IDs."
  EXIT_CODE=0
elif [[ "$FAIL" -gt 0 ]]; then
  echo "${BOLD}${RED}❌ Cortex XDR has problems beyond the core checks -- see [FAIL] lines above.${RESET}"
  echo "   Most important items to fix:"
  for item in "${FAIL_ITEMS[@]}"; do echo "     - $item"; done
  EXIT_CODE=1
elif [[ "$WARN" -gt 0 ]]; then
  echo "${BOLD}✅ Cortex XDR is functioning at the kernel level${RESET}, with $WARN minor item(s) worth a look"
  echo "   (e.g. hostname change or clock sync) -- see [WARN] lines above."
  EXIT_CODE=0
else
  echo "${BOLD}✅ Cortex XDR is fully functioning at the kernel level, no issues detected.${RESET}"
  EXIT_CODE=0
fi

exit "$EXIT_CODE"
