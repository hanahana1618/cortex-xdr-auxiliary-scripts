# Cortex XDR Auxiliary Scripts

Helper scripts for installing and verifying the Palo Alto Networks Cortex XDR
agent, organized per OS since the agent's install layout, service manager,
and process names are different on each platform.

```
linux/
  install-cortex-xdr.sh          # install wrapper + preflight checks
  verify-cortex-xdr-install.sh   # post-install health check (systemd)
macos/
  check-requirements.sh          # pre-deployment readiness check (for MDM)
  verify-cortex-xdr-install.sh   # post-install health check (launchd)
  INSTALL_GUIDE.md                # general MDM deployment walkthrough
windows/
  Check-Requirements.ps1         # pre-deployment readiness check (for MDM)
  verify-cortex-xdr-install.ps1  # post-install health check (SCM)
  INSTALL_GUIDE.md                # general MDM deployment walkthrough
```

There is currently no *install* script for macOS/Windows — only Linux,
since that's the platform these were written for, and macOS/Windows are
typically deployed via MDM (Jamf/Intune/SCCM/GPO) rather than run by hand.
For those platforms this repo instead provides: a **pre-deployment
requirements checker** (run before the MDM push, to catch endpoints that
would fail or silently misconfigure), a **post-install verify script**
(run after, to confirm it actually worked), and an **install guide**
covering the general end-to-end process including the MDM-specific gotchas
(profile approval order on macOS, AV coexistence on Windows).

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
  After installing, it confirms `cytool` landed at `/opt/traps/bin/cytool`
  and prints its version — `cytool` isn't a separate package, it ships
  bundled inside the agent install, so this is a sanity check rather than
  an install step. (Checking for it as a regular user afterward will
  falsely report it missing — `/opt/traps` is root-only traversable
  (`drwx--x--x`); this check runs while the script is still root.)
- **`verify-cortex-xdr-install.sh`** — post-install health check. Beyond
  confirming `traps_pmd` is active/enabled and running (and `cytool`
  status, and recent `/var/log/traps` activity), it also digs into *why*
  a running agent might still not show up correctly in the tenant console:
  - **Kernel vs. user-space mode** — checks `lsmod`/`dmesg`/journal logs
    for the Cortex XDR kernel driver. On uncertified/distro-patched
    kernels (e.g. Pop!_OS), the agent silently falls back to degraded
    user-space/async mode instead of failing loudly. **This is a hard
    `[FAIL]`**, not a warning — an agent stuck in user-space/async mode
    isn't correctly/fully installed, even while the service reports
    "active".
  - **"Kernel Module Locked" detection** — a *different*, specific,
    documented, and actually recoverable condition (repeated ungraceful
    shutdowns tripping a lockout — see PANW KB `kA14u000000CqdACAS`),
    distinct from a genuinely unsupported kernel. Pass `--fix-kernel-lock`
    to apply PANW's documented recovery *only if* that exact condition is
    detected (it briefly disables agent protection — never runs
    automatically, and does nothing for a plain unsupported-kernel case,
    since there is no local command to force kernel mode onto a kernel
    the signed module wasn't built for).
  - **Registration/pairing signals** — greps `traps_pmd.service` logs for
    registration/pairing/connection/error lines. Only a hard `[FAIL]` when
    `cytool`'s own check-in evidence (below) isn't available; otherwise
    informational, since a working agent can log nothing here at all (see
    below).
  - **Clock sync** — via `timedatectl`; skewed clocks can silently break
    TLS/registration.
  - **Distribution-server reachability** — HTTPS reachability to the
    distribution server (defaults to PANW's, or set
    `$CORTEX_DISTRIBUTION_SERVER` for your tenant's).
  - **Hostname stability** — flags if `traps_pmd.service`'s logs show more
    than one hostname since the agent started (e.g. renamed mid-install),
    since the console may have registered the endpoint under a now-stale
    name. Requires systemd.
  - **Tenant check-in evidence** — parses `cytool status`'s "Last
    Successful Check-In time (UTC)" field. **Printed in bold red and
    treated as a hard `[FAIL]`** if that field is missing, empty, or
    "Never" — the agent has never successfully reached the tenant, so the
    install is marked unsuccessful.

    (This check went through a real revision: it originally scanned for a
    "distribution ID" line instead, on the assumption `cytool` would print
    one. Testing against a real, successfully-checked-in agent showed
    `cytool status` doesn't print a distribution ID at all — that version
    of the check produced a false `[FAIL]` on a working install. Check-in
    time is what's actually present in real output and actually proves
    the thing that matters: whether this agent ever reached the tenant.)

    Because of that same finding, the older journalctl-based
    "registration/pairing signals" check below is now informational-only
    whenever cytool's check-in evidence is available — it only counts
    toward PASS/FAIL as a fallback when cytool itself can't be reached.

  The summary line reports passed/warned/failed counts separately and
  will not call an install "healthy" when hard failures are present —
  exit code `1` on any `[FAIL]`.

```bash
# Install
sudo CORTEX_DISTRIBUTION_ID="<your-distribution-id>" \
     CORTEX_DISTRIBUTION_SERVER="https://distributions.traps.paloaltonetworks.com/" \
     ./linux/install-cortex-xdr.sh /path/to/cortex-<version>.sh

# Verify
sudo ./linux/verify-cortex-xdr-install.sh
```

## macos/ ⚠️ untested

> **These scripts have not been run against a real macOS Cortex XDR
> install.** Paths, the launchd discovery logic, and process names were
> built from Palo Alto Networks' public documentation, not verified
> end-to-end on an actual endpoint. Review before use and try on a
> non-production machine first.

- **`check-requirements.sh`** — pre-deployment readiness check, meant to run
  *before* the MDM push (e.g. as a Jamf Extension Attribute or Intune
  detection script) so non-ready devices can be excluded from the install
  scope instead of failing after the fact. Checks CPU/RAM/disk against
  PANW's published minimums, and — the part that most often bites people —
  whether the required MDM configuration profile (System Extension,
  Network Extension, Full Disk Access/PPPC, Notifications, Login Items) is
  already applied. Installing the package before that profile lands can
  "succeed" while leaving the agent silently unable to actually protect
  the endpoint.
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

  Also checks **tenant check-in evidence**, same as Linux: parses
  `cytool status`'s "Last Successful Check-In time (UTC)" field. **Bold
  red `[FAIL]`, install marked unsuccessful** if it's missing/empty/Never.
  This field's wording is confirmed on Linux (cytool is a shared binary
  across platforms) but not independently confirmed on macOS — check the
  raw `cytool status` output this script prints if it looks wrong.
- **`INSTALL_GUIDE.md`** — general walkthrough of the whole deployment: why
  profile-before-package ordering matters, the step-by-step, and a
  requirements table.

```bash
# Before deploying (e.g. wired into an MDM Smart Group / detection script)
sudo ./macos/check-requirements.sh

# After deploying
sudo ./macos/verify-cortex-xdr-install.sh
```

## windows/ ⚠️ untested

> **These scripts have not been run against a real Windows Cortex XDR
> install.** Service/process names and paths were built from Palo Alto
> Networks' public documentation, not verified end-to-end on an actual
> endpoint. Review before use and try on a non-production machine first.

- **`Check-Requirements.ps1`** — pre-deployment readiness check, meant to
  run *before* the MDM push (e.g. as an Intune Win32 app "Requirements"
  script or SCCM detection method). Checks CPU/RAM/disk/.NET Framework
  against PANW's published minimums, and — the part most likely to cause
  real problems — what's currently registered in Windows Security Center.
  Cortex XDR auto-disables Windows Defender on client SKUs but **not** on
  Windows Server, and a pre-existing third-party AV should generally be
  uninstalled (or explicitly excluded) before install to avoid two
  products fighting over the same files.
- **`verify-cortex-xdr-install.ps1`** — post-install health check: confirms
  the install directory (`C:\Program Files\Palo Alto Networks\Traps`) and
  data directory (`C:\ProgramData\Cyvera`) exist, checks the `cyserver`
  Windows service (the main agent service since agent 7.6, replacing the
  older CyveraService/tlaservice/twdservice processes) and related
  driver/filter services, confirms the `cyserver.exe` process is running,
  runs `cytool.exe` if present, and checks recent file activity plus
  related Windows Event Log entries.

  Also checks **tenant check-in evidence**, same approach as Linux/macOS:
  parses `cytool status`'s "Last Successful Check-In time (UTC)" field.
  **Bold red `[FAIL]`, install marked unsuccessful** if it's missing/
  empty/Never (rendered via ANSI escapes layered on `-ForegroundColor
  Red`; Windows Terminal/PowerShell 7+ render this correctly by default).
  This field's wording is confirmed on Linux (cytool is a shared binary
  across platforms) but not independently confirmed on Windows — check
  the raw `cytool status` output this script prints if it looks wrong.

  Run from an elevated (Administrator) PowerShell prompt.
- **`INSTALL_GUIDE.md`** — general walkthrough of the whole deployment: why
  AV coexistence needs deciding up front, the step-by-step, and a
  requirements table.

```powershell
# Before deploying (e.g. wired into an Intune/SCCM requirements check)
.\windows\Check-Requirements.ps1

# After deploying
.\windows\verify-cortex-xdr-install.ps1
```

## What's *not* here (on purpose)

The actual Cortex XDR installer packages are proprietary software
distributed by Palo Alto Networks through your org's Cortex XDR
console/distribution server, along with your `--distribution-id`. Neither
is included in this repo — download installers from your own tenant and
keep distribution credentials out of version control (env vars or a local,
git-ignored conf file).
