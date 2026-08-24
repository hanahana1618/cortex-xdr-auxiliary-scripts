# Cortex XDR Auxiliary Scripts

Helper scripts for installing and verifying the Palo Alto Networks Cortex XDR
agent, organized per OS since the agent's install layout, service manager,
and process names are different on each platform.

```
linux/
  install-cortex-xdr.sh          # install wrapper + preflight checks
  verify-cortex-xdr-install.sh   # post-install health check (systemd)
macos/
  verify-cortex-xdr-install.sh   # post-install health check (launchd)
windows/
  verify-cortex-xdr-install.ps1  # post-install health check (SCM)
```

There is currently no install script for macOS/Windows — only Linux, since
that's the platform these were written for. The macOS and Windows scripts
are verification-only.

## linux/

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
  exists under `/var/log/traps`. Requires systemd.

```bash
# Install
sudo CORTEX_DISTRIBUTION_ID="<your-distribution-id>" \
     CORTEX_DISTRIBUTION_SERVER="https://distributions.traps.paloaltonetworks.com/" \
     ./linux/install-cortex-xdr.sh /path/to/cortex-<version>.sh

# Verify
sudo ./linux/verify-cortex-xdr-install.sh
```

## macos/

- **`verify-cortex-xdr-install.sh`** — post-install health check: confirms
  the install directory exists under `/Library/Application Support/PaloAltoNetworks/Traps`,
  discovers and checks the agent's `launchd` daemon, confirms the agent
  process (`pmd`, or legacy `trapsd` on pre-7.6 agents) is running, runs
  `cytool` if present, and checks recent activity in `/var/log/traps` or the
  macOS unified log.

  Note: Palo Alto Networks doesn't publish an exact, version-stable
  `launchd` daemon label the way they publish the Linux systemd unit name,
  so this script *discovers* the daemon by pattern-matching
  `paloalto`/`traps`/`cortex` in `/Library/LaunchDaemons` and `launchctl list`
  rather than hardcoding a label that could be wrong for your agent version.

```bash
sudo ./macos/verify-cortex-xdr-install.sh
```

## windows/

- **`verify-cortex-xdr-install.ps1`** — post-install health check: confirms
  the install directory (`C:\Program Files\Palo Alto Networks\Traps`) and
  data directory (`C:\ProgramData\Cyvera`) exist, checks the `cyserver`
  Windows service (the main agent service since agent 7.6, replacing the
  older CyveraService/tlaservice/twdservice processes) and related
  driver/filter services, confirms the `cyserver.exe` process is running,
  runs `cytool.exe` if present, and checks recent file activity plus
  related Windows Event Log entries.

  Run from an elevated (Administrator) PowerShell prompt.

```powershell
.\windows\verify-cortex-xdr-install.ps1
```

## What's *not* here (on purpose)

The actual Cortex XDR installer packages are proprietary software
distributed by Palo Alto Networks through your org's Cortex XDR
console/distribution server, along with your `--distribution-id`. Neither
is included in this repo — download installers from your own tenant and
keep distribution credentials out of version control (env vars or a local,
git-ignored conf file).
