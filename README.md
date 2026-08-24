# Cortex XDR Auxiliary Scripts

Small helper scripts for installing and verifying the Palo Alto Networks
Cortex XDR agent on Linux.

## What's here

- **`install-cortex-xdr.sh`** — wraps the standard Cortex XDR Linux agent
  install invocation (`<installer>.sh -- --distribution-server ... --distribution-id ...`),
  reading the distribution credentials from environment variables or a
  local conf file instead of hardcoding them. Before installing, it runs
  preflight checks against Palo Alto Networks' [published Linux agent
  requirements](https://cortex-docs.paloaltonetworks.com/cortex-xdr-agent/9.1/cortex-xdr-agent-for-linux/cortex-xdr-agent-for-linux-requirements):
  root/sudo, 2.3GHz dual-core CPU (checked via core count), 4GB RAM
  minimum (8GB recommended), 10GB free disk space for `/opt/traps`,
  `openssl`/`ca-certificates`/`glibc` presence, SELinux status, distro
  family (flags anything outside PANW's officially certified list, e.g.
  Ubuntu/Debian derivatives like Pop!_OS), and HTTPS reachability to the
  distribution server on port 443. Pass `--skip-checks` to bypass them.
- **`verify-cortex-xdr-install.sh`** — post-install health check: confirms
  the `traps_pmd` systemd service is active/enabled, the agent process is
  running, `cytool` reports status (if present), and recent log activity
  exists under `/var/log/traps`.

## What's *not* here (on purpose)

The actual Cortex XDR installer package (e.g. `cortex-<version>.sh`) is
proprietary software distributed by Palo Alto Networks through your
org's Cortex XDR console/distribution server, along with your
`--distribution-id`. Neither is included in this repo — download the
installer from your own tenant and keep your distribution ID out of
version control (env var or a local, git-ignored conf file).

## Usage

```bash
# Install
sudo CORTEX_DISTRIBUTION_ID="<your-distribution-id>" \
     CORTEX_DISTRIBUTION_SERVER="https://distributions.traps.paloaltonetworks.com/" \
     ./install-cortex-xdr.sh /path/to/cortex-<version>.sh

# Verify
sudo ./verify-cortex-xdr-install.sh
```
