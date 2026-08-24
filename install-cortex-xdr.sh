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
set -euo pipefail

INSTALLER="${1:-}"
CONF_FILE="${2:-}"

usage() {
  echo "Usage: sudo $0 <path-to-cortex-installer.sh> [path-to-cortex.conf]" >&2
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

echo "== Installing Cortex XDR agent =="
echo "Installer:            $INSTALLER"
echo "Distribution server:  $DISTRIBUTION_SERVER"
echo "Distribution ID:      ${DISTRIBUTION_ID:0:6}************************"

chmod +x "$INSTALLER"
bash "$INSTALLER" -- \
  --distribution-server "$DISTRIBUTION_SERVER" \
  --distribution-id "$DISTRIBUTION_ID"

echo "== Install command finished. Run verify-cortex-xdr-install.sh to confirm the agent is healthy. =="
