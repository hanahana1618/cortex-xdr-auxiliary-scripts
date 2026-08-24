#!/usr/bin/env bash
#
# install-cortex-xdr.sh
#
# Wrapper for installing the Palo Alto Networks Cortex XDR Linux agent.
#
# The actual Cortex XDR agent package (e.g. cortex-9.3.0.220.sh) is a
# proprietary, license-restricted Makeself installer distributed by Palo
# Alto Networks through your org's Cortex XDR console / distribution
# server. It is NOT included in this repo and must not be redistributed
# publicly. Download it yourself from your Cortex XDR tenant before
# running this script.
#
# This script just wraps the documented install invocation so the
# distribution credentials (--distribution-id / --distribution-server)
# are supplied via environment variables or a local, git-ignored conf
# file instead of being hardcoded or committed anywhere.
#
# Usage:
#   sudo CORTEX_DISTRIBUTION_ID="xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx" \
#        CORTEX_DISTRIBUTION_SERVER="https://distributions.traps.paloaltonetworks.com/" \
#        ./install-cortex-xdr.sh /path/to/cortex-<version>.sh
#
# or, with a local conf file (two lines, never commit this file):
#   --distribution-id <id>
#   --distribution-server <url>
#
#   sudo ./install-cortex-xdr.sh /path/to/cortex-<version>.sh ./cortex.conf
#
# Preflight checks (below) enforce the minimum system requirements Palo
# Alto Networks publishes for the Cortex XDR Linux agent:
#   https://cortex-docs.paloaltonetworks.com/cortex-xdr-agent/ (Linux Requirements page)
#   - root/sudo privileges
#   - 2.3 GHz dual-core processor minimum
#   - 4 GB RAM minimum (8 GB recommended)
#   - 10 GB free disk space available to /opt/traps
#   - outbound TCP/443 reachability to the distribution server
#   - openssl 1.0.0+ and ca-certificates installed
#   - glibc present
#   - SELinux status reported (informational; agent supports enforcing
#     mode on supported distros with the correct policy packages)
#
# Pass --skip-checks to bypass the preflight checks (e.g. on a distro PANW
# supports that this script doesn't recognize).
#
set -euo pipefail

SKIP_CHECKS=0
ARGS=()
for arg in "$@"; do
  if [[ "$arg" == "--skip-checks" ]]; then
    SKIP_CHECKS=1
  else
    ARGS+=("$arg")
  fi
done

INSTALLER="${ARGS[0]:-}"
CONF_FILE="${ARGS[1]:-}"

usage() {
  echo "Usage: sudo $0 <path-to-cortex-installer.sh> [path-to-cortex.conf] [--skip-checks]" >&2
  echo "       (or set CORTEX_DISTRIBUTION_ID / CORTEX_DISTRIBUTION_SERVER env vars)" >&2
  exit 1
}

if [[ -z "$INSTALLER" || ! -f "$INSTALLER" ]]; then
  echo "ERROR: installer path not found: '${INSTALLER}'" >&2
  usage
fi

if [[ "$(id -u)" -ne 0 ]]; then
  echo "ERROR: this script must be run as root (sudo)." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Preflight: minimum system requirements per PANW's published Linux agent
# requirements (CPU/RAM/disk/network/library prerequisites).
# ---------------------------------------------------------------------------
preflight_checks() {
  local hard_fail=0

  echo "== Preflight: Cortex XDR Linux agent requirements =="

  # Supported OS family (best-effort; see PANW's Compatibility Matrix for
  # the definitive, version-specific list before installing).
  if [[ -r /etc/os-release ]]; then
    . /etc/os-release
    echo "[INFO] OS detected: ${PRETTY_NAME:-unknown}"
    case "${ID:-}" in
      rhel|centos|amzn|ubuntu|debian|ol|sles|opensuse*|rocky|almalinux)
        echo "[PASS] OS family ($ID) is in the generally-supported list" ;;
      *)
        if [[ "${ID_LIKE:-}" == *ubuntu* || "${ID_LIKE:-}" == *debian* ]]; then
          echo "[WARN] OS ($ID) is not itself PANW-certified, but is a ${ID_LIKE} derivative (e.g. Pop!_OS) -- not officially supported, install at your own risk / check the Compatibility Matrix"
        else
          echo "[WARN] OS family ($ID) not in this script's known-supported list -- check the Compatibility Matrix"
        fi
        ;;
    esac
  else
    echo "[WARN] Could not read /etc/os-release to determine distro"
  fi

  # CPU: 2.3 GHz dual-core minimum -> check core count (clock speed varies
  # by cloud/virt platform and isn't reliably introspectable).
  local cores
  cores=$(nproc 2>/dev/null || echo 0)
  if [[ "$cores" -ge 2 ]]; then
    echo "[PASS] CPU cores: $cores (>= 2 required)"
  else
    echo "[FAIL] CPU cores: $cores (2+ dual-core @ 2.3GHz required)"
    hard_fail=1
  fi

  # RAM: 4 GB minimum, 8 GB recommended.
  local mem_kb mem_mb
  mem_kb=$(awk '/MemTotal/{print $2}' /proc/meminfo 2>/dev/null || echo 0)
  mem_mb=$((mem_kb / 1024))
  if [[ "$mem_mb" -ge 4096 ]]; then
    if [[ "$mem_mb" -ge 8192 ]]; then
      echo "[PASS] RAM: ${mem_mb}MB (meets 8GB recommended)"
    else
      echo "[WARN] RAM: ${mem_mb}MB (meets 4GB minimum, but 8GB is recommended)"
    fi
  else
    echo "[FAIL] RAM: ${mem_mb}MB (4GB minimum required)"
    hard_fail=1
  fi

  # Disk: 10 GB free available to /opt/traps.
  local install_root="/opt"
  local avail_kb avail_gb
  avail_kb=$(df -Pk "$install_root" 2>/dev/null | awk 'NR==2{print $4}')
  avail_gb=$(( ${avail_kb:-0} / 1024 / 1024 ))
  if [[ "${avail_gb:-0}" -ge 10 ]]; then
    echo "[PASS] Disk space on $install_root: ${avail_gb}GB free (>= 10GB required)"
  else
    echo "[FAIL] Disk space on $install_root: ${avail_gb}GB free (10GB required for /opt/traps)"
    hard_fail=1
  fi

  # openssl >= 1.0.0
  if command -v openssl >/dev/null 2>&1; then
    echo "[PASS] openssl present: $(openssl version)"
  else
    echo "[FAIL] openssl not found (1.0.0+ required)"
    hard_fail=1
  fi

  # ca-certificates (best-effort check for a populated CA bundle)
  if [[ -s /etc/ssl/certs/ca-certificates.crt || -d /etc/pki/tls/certs ]]; then
    echo "[PASS] CA certificate bundle found"
  else
    echo "[WARN] Could not confirm a ca-certificates bundle is installed"
  fi

  # glibc present
  if ldd --version >/dev/null 2>&1; then
    echo "[PASS] glibc present: $(ldd --version | head -n1)"
  else
    echo "[WARN] Could not confirm glibc via ldd"
  fi

  # SELinux status (informational only -- agent supports enforcing mode
  # with the correct policy packages on supported distros).
  if command -v getenforce >/dev/null 2>&1; then
    echo "[INFO] SELinux status: $(getenforce)"
  fi

  # Network reachability to the distribution server on 443.
  if [[ -n "${DISTRIBUTION_SERVER:-}" ]] && command -v curl >/dev/null 2>&1; then
    if curl -sS --max-time 5 -o /dev/null "$DISTRIBUTION_SERVER"; then
      echo "[PASS] Distribution server reachable over HTTPS: $DISTRIBUTION_SERVER"
    else
      echo "[WARN] Could not reach $DISTRIBUTION_SERVER over HTTPS (check outbound TCP/443 / proxy)"
    fi
  fi

  if [[ "$hard_fail" -eq 1 ]]; then
    echo
    echo "ERROR: one or more minimum requirements were not met. Re-run with --skip-checks to override." >&2
    exit 1
  fi
  echo "== Preflight checks complete =="
  echo
}

DISTRIBUTION_ID="${CORTEX_DISTRIBUTION_ID:-}"
DISTRIBUTION_SERVER="${CORTEX_DISTRIBUTION_SERVER:-}"

if [[ -n "$CONF_FILE" && -f "$CONF_FILE" ]]; then
  # Expect lines like:
  #   --distribution-id <id>
  #   --distribution-server <url>
  DISTRIBUTION_ID="${DISTRIBUTION_ID:-$(awk '/--distribution-id/{print $2}' "$CONF_FILE")}"
  DISTRIBUTION_SERVER="${DISTRIBUTION_SERVER:-$(awk '/--distribution-server/{print $2}' "$CONF_FILE")}"
fi

if [[ -z "$DISTRIBUTION_ID" || -z "$DISTRIBUTION_SERVER" ]]; then
  echo "ERROR: missing distribution-id / distribution-server." >&2
  echo "Set CORTEX_DISTRIBUTION_ID and CORTEX_DISTRIBUTION_SERVER, or pass a conf file." >&2
  usage
fi

if [[ "$SKIP_CHECKS" -eq 1 ]]; then
  echo "== Skipping preflight checks (--skip-checks passed) =="
else
  preflight_checks
fi

echo "== Installing Cortex XDR agent =="
echo "Installer:            $INSTALLER"
echo "Distribution server:  $DISTRIBUTION_SERVER"
echo "Distribution ID:      ${DISTRIBUTION_ID:0:6}************************"

chmod +x "$INSTALLER"
bash "$INSTALLER" -- \
  --distribution-server "$DISTRIBUTION_SERVER" \
  --distribution-id "$DISTRIBUTION_ID"

echo "== Install command finished. Run verify-cortex-xdr-install.sh to confirm the agent is healthy. =="
