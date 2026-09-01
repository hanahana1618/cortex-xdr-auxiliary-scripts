#!/usr/bin/env bash
#
# verify-cortex-xdr-install.sh (macOS)
#
# *** UNTESTED: this script has NOT been run against a real macOS Cortex ***
# *** XDR install. Paths, process names, and the launchd discovery logic ***
# *** below were built from Palo Alto Networks' public documentation,    ***
# *** not verified end-to-end on an actual endpoint. Review it and try   ***
# *** it on a non-production machine before relying on its output.       ***
#
# Post-install health check for the Palo Alto Networks Cortex XDR macOS
# agent. Checks the install directory, the launchd daemon, the running
# agent process, cytool status (if present), and recent logs.
#
# This is NOT the same script as linux/verify-cortex-xdr-install.sh --
# macOS has no systemd, a different install path, and a different
# process/service naming scheme, so the checks are implemented natively
# for macOS rather than branched inside one shared script.
#
# Notes on accuracy: Palo Alto Networks does not publish an exact,
# version-stable launchd daemon label (e.g. "com.paloaltonetworks.*") the
# way they publish the Linux systemd unit name, and it has changed across
# agent releases. Rather than hardcode a label that may be wrong for your
# installed version, this script *discovers* the daemon by pattern-matching
# on "paloalto"/"traps"/"cortex" in /Library/LaunchDaemons and in
# `launchctl list`, and reports what it finds.
#
# Agent process name: since Cortex XDR agent 7.6, the "pmd" process
# replaced the older "trapsd" process (matches the Linux agent's
# traps_pmd.service naming). This script checks for both to cover
# older and newer installs.
#
# Usage:
#   sudo ./verify-cortex-xdr-install.sh
#
# Exit codes:
#   0 - agent appears installed and running
#   1 - agent not found / not running / checks failed
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

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "ERROR: this script is for macOS only (detected: $(uname -s))." >&2
  exit 1
fi

echo "== Cortex XDR install verification (macOS) =="
echo "Host: $(hostname)   macOS: $(sw_vers -productVersion 2>/dev/null)   Date: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo "!! DISCLAIMER: this script has not been tested against a real Cortex XDR install on macOS. !!"
echo "!! Treat its output as a starting point, not a confirmed result.                            !!"
echo

# 1. Install directory present
INSTALL_DIR="/Library/Application Support/PaloAltoNetworks/Traps"
check "Install directory exists ($INSTALL_DIR)" test -d "$INSTALL_DIR"

# 2. launchd daemon: discover by pattern rather than a hardcoded label,
#    since the exact label isn't stable/published across agent versions.
echo
echo "-- Searching for the Cortex XDR launchd daemon --"
FOUND_PLIST="$(find /Library/LaunchDaemons -maxdepth 1 -iname "*paloalto*" -o -iname "*traps*" -o -iname "*cortex*" 2>/dev/null | head -n1)"
FOUND_LABEL="$(launchctl list 2>/dev/null | awk 'tolower($0) ~ /paloalto|traps|cortex/ {print $3; exit}')"

if [[ -n "$FOUND_PLIST" ]]; then
  echo "[PASS] Found LaunchDaemon plist: $FOUND_PLIST"
  PASS=$((PASS + 1))
else
  echo "[FAIL] No LaunchDaemon plist matching paloalto/traps/cortex found in /Library/LaunchDaemons"
  FAIL=$((FAIL + 1))
fi

if [[ -n "$FOUND_LABEL" ]]; then
  echo "[PASS] Daemon is loaded in launchctl: $FOUND_LABEL"
  PASS=$((PASS + 1))
  LABEL_STATUS="$(launchctl list "$FOUND_LABEL" 2>/dev/null | awk -F'"' '/"PID"/{print "running (PID present)"} /"LastExitStatus"/{print}')"
  [[ -n "$LABEL_STATUS" ]] && echo "       $LABEL_STATUS"
else
  echo "[FAIL] No matching daemon found loaded in 'launchctl list'"
  FAIL=$((FAIL + 1))
fi

# 3. Agent process running (pmd on 7.6+, trapsd on older agents)
echo
check "Cortex XDR process running (pmd)" bash -c "pgrep -x pmd >/dev/null || pgrep -f 'Traps.*pmd' >/dev/null"
if ! pgrep -x pmd >/dev/null 2>&1; then
  if pgrep -x trapsd >/dev/null 2>&1; then
    echo "[INFO] 'trapsd' process found instead -- this is the legacy process name (pre-7.6 agent)"
  fi
fi

# 4. cytool status, if present
CYTOOL="$(find "$INSTALL_DIR" -maxdepth 3 -iname cytool 2>/dev/null | head -n1)"
if [[ -n "$CYTOOL" && -x "$CYTOOL" ]]; then
  echo
  echo "-- cytool runtimequery --"
  sudo "$CYTOOL" runtimequery 2>&1 | sed 's/^/  /' || true
  check "cytool reports agent status" bash -c "sudo '$CYTOOL' runtimequery >/dev/null 2>&1"

  # 4b. Distribution ID configured.
  #     CAVEAT: PANW does not publicly document an exact field name/label
  #     for this in cytool's output, so this is a best-effort scan of
  #     `cytool status` + `runtimequery` text for any line mentioning
  #     "distribution", checking it has a non-empty, non-placeholder value.
  #     If your agent version's cytool wording differs, adjust the grep
  #     pattern below to match what you actually see -- don't trust this
  #     blindly without checking real output on a known-good install first.
  echo
  echo "-- Distribution ID --"
  DIST_ID_LINE="$( (sudo "$CYTOOL" status 2>/dev/null; sudo "$CYTOOL" runtimequery 2>/dev/null) | grep -i "distribution" | head -n1)"
  DIST_ID_VALUE="$(echo "$DIST_ID_LINE" | sed -E 's/^[^:=]*[:=][[:space:]]*//' | tr -d '[:space:]')"
  case "$(echo "$DIST_ID_VALUE" | tr '[:upper:]' '[:lower:]')" in
    ""|"n/a"|"none"|"0"|"null"|"unset")
      echo "${BOLD}${RED}[FAIL] No distribution ID appears to be set on this agent.${RESET}"
      echo "${BOLD}${RED}       This installation is UNSUCCESSFUL -- the agent was never told which${RESET}"
      echo "${BOLD}${RED}       tenant to register with. Reinstall with a valid distribution ID.${RESET}"
      FAIL=$((FAIL + 1))
      ;;
    *)
      echo "[PASS] Distribution ID appears set: $DIST_ID_LINE"
      PASS=$((PASS + 1))
      ;;
  esac
else
  echo "[SKIP] cytool not found under '$INSTALL_DIR' (path may differ by version, or this"
  echo "       script isn't running as root)."
  echo "[SKIP] Cannot confirm distribution ID without cytool -- re-run with sudo to check it."
fi

# 5. Recent log activity
echo
LOGDIR="/var/log/traps"
if [[ -d "$LOGDIR" ]]; then
  RECENT=$(find "$LOGDIR" -type f -mmin -5 2>/dev/null | wc -l | tr -d ' ')
  if [[ "$RECENT" -gt 0 ]]; then
    echo "[PASS] Recent log activity in $LOGDIR (last 5 min)"
    PASS=$((PASS + 1))
  else
    echo "[WARN] No log activity in $LOGDIR in the last 5 minutes (may be normal if idle)"
  fi
else
  echo "[SKIP] $LOGDIR not found -- checking macOS unified log instead"
  if command -v log >/dev/null 2>&1; then
    UNIFIED_HITS=$(log show --last 5m --predicate 'process == "pmd" OR process == "trapsd"' 2>/dev/null | wc -l | tr -d ' ')
    if [[ "${UNIFIED_HITS:-0}" -gt 0 ]]; then
      echo "[PASS] Recent unified-log activity for pmd/trapsd (last 5 min, $UNIFIED_HITS lines)"
      PASS=$((PASS + 1))
    else
      echo "[WARN] No recent unified-log activity found for pmd/trapsd (may be normal if idle, or may need sudo)"
    fi
  fi
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
