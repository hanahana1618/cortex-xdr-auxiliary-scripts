# Installing Cortex XDR on macOS via MDM — General Guide

> ⚠️ This is a general process guide assembled from Palo Alto Networks'
> public documentation, not a step-by-step verified against a real
> deployment. Treat it as a checklist to adapt to your specific MDM
> (Jamf, Intune, etc.) and agent version — confirm exact screens/fields
> against your own console and the Cortex XDR Agent Administrator Guide
> for the version you're running.

## Why order matters here

Unlike Linux (one installer script, one set of CLI flags), the macOS
agent needs the OS to grant it several sensitive permissions — a System
Extension, a Network Extension (content filter), Full Disk Access, and
Login Items. If you push the `.pkg` to a device **before** those
permissions are pre-approved via MDM, macOS will either prompt the end
user to click "Allow" on each one (easy to miss/dismiss) or, on a
supervised/MDM-managed device without prompts enabled, silently deny
them — the install "succeeds" but the agent doesn't actually have the
access it needs to protect the endpoint. That's the failure mode this
guide (and `check-requirements.sh`) is built around avoiding.

## Step-by-step

1. **Get your distribution package.** From the Cortex XDR console,
   download the macOS agent `.pkg` for your target agent version, tied to
   your org's distribution ID.

2. **Deploy PANW's unified MDM configuration profile *first*, to your
   whole target scope, before the package.** This profile pre-approves:
   - System Extension
   - Network Extension / content filter
   - Notifications
   - Login Items
   - Full Disk Access (via a Privacy Preferences Policy Control payload)

   PANW publishes this as a signed, MDM-agnostic configuration profile —
   upload it to Jamf/Intune/whatever MDM you use as a standard
   configuration profile payload, scoped to the same devices that will
   get the agent.

3. **Confirm the profile actually landed before pushing the package.**
   Don't assume profile deployment succeeded just because you clicked
   "push" — MDM profile delivery can lag or silently fail per-device.
   Use `check-requirements.sh` (this folder) as a Jamf Extension
   Attribute / Intune detection script, and gate the package deployment
   on devices where it reports the profile is present (`[PASS]` on the
   "MDM configuration profiles" check).

4. **Push the package.** Under the hood this is:
   ```bash
   sudo installer -pkg "CortexXDR.pkg" -target /
   ```
   For a fully unattended install, PANW's packaging expects a
   `Config.xml` (containing your distribution ID/server) in the **same
   directory** as the `.pkg` at install time — this file is generated
   for you when you download the agent from the console; don't
   hand-write it. Most MDMs handle this by bundling both files together
   in the same deployment package rather than you invoking `installer`
   directly.

5. **Verify.** Run [`verify-cortex-xdr-install.sh`](verify-cortex-xdr-install.sh)
   (this folder) against a sample of freshly-deployed devices to confirm
   the launchd daemon is running and the install directory is populated
   — don't rely on "MDM says it installed" alone, given the silent-permission-denial
   failure mode above.

## Requirements checklist (see `check-requirements.sh` for the automated version)

| Requirement | Minimum | Recommended |
|---|---|---|
| CPU | Intel (SSE2) or Apple Silicon (M-series) | — |
| RAM | 512 MB | 2 GB |
| Disk space | 5 GB free | 20 GB free |
| Network | Outbound TCP/443 to your distribution/management server | — |
| macOS version | Check PANW's Compatibility Matrix for your agent version | — |
| MDM profiles | Unified config profile applied *before* package install | — |

Source: [Cortex XDR Agent for macOS Requirements](https://cortex-docs.paloaltonetworks.com/cortex-xdr-agent/9.0/cortex-xdr-agent-for-macos/cortex-xdr-agent-for-mac-requirements),
[Install with a unified configuration profile for MDMs](https://cortex-docs.paloaltonetworks.com/cortex-xdr-agent/9.2/cortex-xdr-agent-for-macos/install-the-cortex-xdr-agent-for-mac/install-with-a-unified-configuration-profile-for-mdms)
