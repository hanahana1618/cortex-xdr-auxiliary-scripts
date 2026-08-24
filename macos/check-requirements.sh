#!/usr/bin/env bash
#
# check-requirements.sh (macOS)
#
# *** UNTESTED: this script has NOT been run against a real macOS Cortex ***
# *** XDR deployment. Requirements below are from Palo Alto Networks'    ***
# *** public documentation, not verified end-to-end. Pilot it on a      ***
# *** handful of real devices before wiring it into a fleet-wide MDM    ***
# *** Smart Group / scope before trusting its exit code.                ***
#
# Pre-deployment readiness check for the Cortex XDR macOS agent. Intended
# to run BEFORE the agent package is pushed via MDM (Jamf/Intune/etc) --
# either interactively, or wired in as a Jamf Extension Attribute / Intune
# Custom Attribute so devices that fail can be excluded from the install
# scope (Smart Group) until fixed.
#
# Source for hardware minimums:
#   https://cortex-docs.paloaltonetworks.com/cortex-xdr-agent/9.0/cortex-xdr-agent-for-macos/cortex-xdr-agent-for-mac-requirements
#     - CPU: Intel (SSE2) or Apple Silicon (M-series / ARM)
#     - RAM: 512MB minimum, 2GB recommended
#     - Disk: 5GB minimum, 20GB recommended
#     - Network: outbound TCP/443 to the distribution/management server
#
# Source for MDM/profile prerequisites (this is the part that actually
# causes silent installs to "succeed" but leave the agent non-functional):
#   https://cortex-docs.paloaltonetworks.com/cortex-xdr-agent/9.2/cortex-xdr-agent-for-macos/install-the-cortex-xdr-agent-for-mac/install-with-a-unified-configuration-profile-for-mdms
#   PANW publishes a *unified MDM configuration profile* that must be
#   deployed and applied BEFORE the package installs, pre-approving:
#     - System Extension
#     - Content/Network Filter (Network Extension)
#     - Notifications
#     - Login Items
#     - Full Disk Access (Privacy Preferences Policy Control / PPPC)
#   Push the package to a device that doesn't have these profiles applied
#   yet and the install can "complete" while the agent silently lacks the
#   permissions it needs to actually protect the endpoint -- there's no
#   loud error, which is exactly the kind of issue this script is meant
#   to catch beforehand.
#
#   PANW does not publish a single stable bundle ID / Team ID list in
#   their public docs (their community/Jamf forum guidance is to extract
#   it yourself from a pilot machine's approved profile). So rather than
#   hardcode identifiers that may be wrong for your agent version, this
#   script checks `profiles show` / `systemextensionsctl list` for entries
#   matching "paloalto"/"traps"/"cortex" and reports what it finds -- you
#   should confirm the exact identifiers against your own MDM's deployed
#   profile once, then tighten this check for your environment.
#
# Usage:
#   sudo ./check-requirements.sh
#
# Exit codes:
#   0 - ready for deployment
#   1 - one or more hard requirements failed
#
set -uo pipefail

PASS=0
FAIL=0
WARN=0

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "ERROR: this script is for macOS only (detected: $(uname -s))." >&2
  exit 1
fi

echo "== Cortex XDR pre-deployment requirements check (macOS) =="
echo "Host: $(hostname)   macOS: $(sw_vers -productVersion 2>/dev/null)   Date: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo "!! DISCLAIMER: not tested against a real Cortex XDR deployment. Pilot before fleet-wide use. !!"
echo

# --- OS version -------------------------------------------------------
OS_VERSION="$(sw_vers -productVersion 2>/dev/null)"
OS_MAJOR="$(echo "$OS_VERSION" | cut -d. -f1)"
echo "[INFO] macOS version: ${OS_VERSION:-unknown} -- cross-check against PANW's Compatibility Matrix for your specific agent version"
if [[ -n "$OS_MAJOR" && "$OS_MAJOR" -ge 11 ]]; then
  echo "[PASS] macOS major version ($OS_MAJOR) is reasonably current"
  PASS=$((PASS + 1))
else
  echo "[WARN] macOS major version ($OS_MAJOR) is old -- confirm it's still supported by your agent version"
  WARN=$((WARN + 1))
fi

# --- CPU ----------------------------------------------------------------
ARCH="$(uname -m)"
if [[ "$ARCH" == "arm64" || "$ARCH" == "x86_64" ]]; then
  echo "[PASS] CPU architecture supported: $ARCH (Apple Silicon and Intel are both supported)"
  PASS=$((PASS + 1))
else
  echo "[FAIL] Unrecognized/unsupported CPU architecture: $ARCH"
  FAIL=$((FAIL + 1))
fi

# --- RAM ------------------------------------------------------------------
MEM_BYTES="$(sysctl -n hw.memsize 2>/dev/null || echo 0)"
MEM_MB=$((MEM_BYTES / 1024 / 1024))
if [[ "$MEM_MB" -ge 512 ]]; then
  if [[ "$MEM_MB" -ge 2048 ]]; then
    echo "[PASS] RAM: ${MEM_MB}MB (meets 2GB recommended)"
  else
    echo "[WARN] RAM: ${MEM_MB}MB (meets 512MB minimum, but 2GB is recommended)"
    WARN=$((WARN + 1))
  fi
  PASS=$((PASS + 1))
else
  echo "[FAIL] RAM: ${MEM_MB}MB (512MB minimum required)"
  FAIL=$((FAIL + 1))
fi

# --- Disk space -------------------------------------------------------
AVAIL_BYTES="$(df -k / 2>/dev/null | awk 'NR==2{print $4 * 1024}')"
AVAIL_GB=$(( ${AVAIL_BYTES:-0} / 1024 / 1024 / 1024 ))
if [[ "${AVAIL_GB:-0}" -ge 5 ]]; then
  if [[ "$AVAIL_GB" -ge 20 ]]; then
    echo "[PASS] Disk space on /: ${AVAIL_GB}GB free (meets 20GB recommended)"
  else
    echo "[WARN] Disk space on /: ${AVAIL_GB}GB free (meets 5GB minimum, but 20GB is recommended)"
    WARN=$((WARN + 1))
  fi
  PASS=$((PASS + 1))
else
  echo "[FAIL] Disk space on /: ${AVAIL_GB}GB free (5GB minimum required)"
  FAIL=$((FAIL + 1))
fi

# --- Network reachability (443 to distribution/management server) ------
if [[ -n "${CORTEX_DISTRIBUTION_SERVER:-}" ]] && command -v curl >/dev/null 2>&1; then
  if curl -sS --max-time 5 -o /dev/null "$CORTEX_DISTRIBUTION_SERVER"; then
    echo "[PASS] Distribution server reachable over HTTPS: $CORTEX_DISTRIBUTION_SERVER"
    PASS=$((PASS + 1))
  else
    echo "[WARN] Could not reach $CORTEX_DISTRIBUTION_SERVER over HTTPS (check outbound TCP/443 / proxy)"
    WARN=$((WARN + 1))
  fi
else
  echo "[SKIP] Set \$CORTEX_DISTRIBUTION_SERVER to also test HTTPS reachability to your distribution server"
fi

# --- MDM configuration profiles (the important, easy-to-miss part) -----
echo
echo "-- MDM configuration profiles (System Extension / PPPC / Network Extension) --"
if command -v profiles >/dev/null 2>&1; then
  PROFILE_HITS="$(profiles show 2>/dev/null | grep -iE 'paloalto|traps|cortex' | wc -l | tr -d ' ')"
  if [[ "${PROFILE_HITS:-0}" -gt 0 ]]; then
    echo "[PASS] Found $PROFILE_HITS installed configuration profile(s) matching paloalto/traps/cortex"
    PASS=$((PASS + 1))
  else
    echo "[FAIL] No MDM configuration profile matching paloalto/traps/cortex is installed yet."
    echo "       Deploy PANW's unified MDM configuration profile (System Extension, PPPC/Full Disk"
    echo "       Access, Network Extension, Notifications, Login Items) BEFORE pushing the .pkg,"
    echo "       or the install can 'succeed' while the agent silently lacks required permissions."
    FAIL=$((FAIL + 1))
  fi
else
  echo "[SKIP] 'profiles' command not available to check MDM profile status"
fi

if command -v systemextensionsctl >/dev/null 2>&1; then
  SYSEXT_HITS="$(systemextensionsctl list 2>/dev/null | grep -iE 'paloalto|traps|cortex' | wc -l | tr -d ' ')"
  if [[ "${SYSEXT_HITS:-0}" -gt 0 ]]; then
    echo "[INFO] Found $SYSEXT_HITS matching system extension entry/entries already registered"
  else
    echo "[INFO] No matching system extension registered yet (expected pre-install if this is a fresh device)"
  fi
fi

echo
echo "== Summary: $PASS passed, $WARN warned, $FAIL failed =="
if [[ "$FAIL" -eq 0 ]]; then
  echo "Device appears ready for Cortex XDR deployment."
  exit 0
else
  echo "Device is NOT ready -- resolve [FAIL] items above before deploying."
  exit 1
fi
