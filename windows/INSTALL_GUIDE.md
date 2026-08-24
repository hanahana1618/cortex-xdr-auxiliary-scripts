# Installing Cortex XDR on Windows via MDM — General Guide

> ⚠️ This is a general process guide assembled from Palo Alto Networks'
> public documentation, not a step-by-step verified against a real
> deployment. Treat it as a checklist to adapt to your specific MDM
> (Intune, SCCM, GPO, etc.) and agent version — confirm exact
> screens/fields against your own console and the Cortex XDR Agent
> Administrator Guide for the version you're running.

## Why order matters here

The Windows agent's biggest pre-install risk isn't permissions (like
macOS) — it's **AV conflicts**. Cortex XDR registers itself with the
Windows Security Center as an antivirus product. On client SKUs, Windows
will then auto-disable Microsoft Defender for you. On **Windows Server**,
that auto-disable does *not* happen — Defender keeps running alongside
Cortex XDR unless you disable/remove it yourself, which can cause
resource contention or scanning conflicts. If a third-party AV (not
Defender) is already installed, PANW's guidance is to uninstall it before
installing Cortex XDR, or explicitly configure mutual exclusions if
coexistence is required. Sorting this out *before* the MDM push avoids
ending up with two security products fighting over the same files.

## Step-by-step

1. **Get your distribution package.** From the Cortex XDR console,
   download the Windows agent `.msi` for your target agent version, tied
   to your org's distribution ID.

2. **Decide your AV coexistence strategy per device class** before you
   scope the deployment:
   - Client SKUs (Win10/11) with only Defender present: no action needed,
     Cortex XDR will register and Defender auto-disables.
   - Client SKUs with a third-party AV present: uninstall it, or plan
     explicit exclusions for both products if coexistence is required.
   - Windows Server: manually disable/remove Defender yourself — it will
     **not** auto-disable.

3. **Confirm each device meets requirements and doesn't have an
   unresolved AV conflict before pushing.** Use `Check-Requirements.ps1`
   (this folder) as an Intune Win32 app "Requirements" script, an SCCM
   detection method, or a GPO pre-check gate — it reports registered AV
   products and flags anything other than Defender as a `[WARN]`.

4. **Push the package.** Under the hood this is a standard silent MSI
   install:
   ```powershell
   msiexec /i cortexxdr.msi /qn /L*v C:\logs\cortex-install.log
   ```
   PANW restricts which MSI properties the installer actually supports
   (no custom install directory, for example) — check the Administrator
   Guide for your agent version for the exact property names to pass
   your distribution ID/server (these aren't consistently documented in
   public sources, unlike the Linux CLI flags, so confirm against your
   own console's packaging instructions or generated install command).
   Package this as an Intune Win32 app, an SCCM application, or a GPO
   software install rather than running `msiexec` by hand across a
   fleet.

5. **Verify.** Run [`verify-cortex-xdr-install.ps1`](verify-cortex-xdr-install.ps1)
   (this folder) against a sample of freshly-deployed devices to confirm
   the `cyserver` service is running and registered correctly, rather
   than trusting "Intune says installed" alone.

## Requirements checklist (see `Check-Requirements.ps1` for the automated version)

| Requirement | Minimum | Recommended |
|---|---|---|
| CPU | Intel Pentium Dual Core+/SSE2, AMD Opteron/Athlon 64+/SSE2, or ARM64 (Win11 23H2+ only) | — |
| RAM | 2 GB | — |
| Disk space | 5 GB free | 20 GB free |
| .NET Framework | Varies by OS — Win8: 4.5, Win8.1: 4.5.1, Win10+: 4.6, Server 2008 R2: 3.5 SP1, Server 2012: 4.5, Server 2012 R2+: 4.5.1 | — |
| Network | Outbound TCP/443 to your distribution/management server | — |
| AV coexistence | Third-party AV uninstalled, or exclusions configured; Defender manually disabled on Server SKUs | — |

Source: [Cortex XDR Agent for Windows Requirements](https://cortex-docs.paloaltonetworks.com/cortex-xdr-agent/9.0/cortex-xdr-agent-for-windows/cortex-xdr-agent-for-windows-requirements)
