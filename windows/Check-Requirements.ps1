<#
.SYNOPSIS
    Pre-deployment readiness check for the Cortex XDR Windows agent.

    *** UNTESTED: this script has NOT been run against a real Windows   ***
    *** Cortex XDR deployment. Requirements below are from Palo Alto    ***
    *** Networks' public documentation, not verified end-to-end. Pilot  ***
    *** it on a handful of real devices before wiring it into Intune/   ***
    *** SCCM/GPO requirement logic for a fleet-wide push.               ***

.DESCRIPTION
    Intended to run BEFORE the agent MSI is pushed via MDM (Intune Win32
    app "Requirements" script, SCCM detection method, or a GPO startup
    script gate) -- so devices that would fail the install, or that have
    a conflicting AV product installed, can be excluded/flagged before
    the push instead of after.

    Source for hardware/software minimums:
      https://cortex-docs.paloaltonetworks.com/cortex-xdr-agent/9.0/cortex-xdr-agent-for-windows/cortex-xdr-agent-for-windows-requirements
        - CPU: Intel Pentium Dual Core+/SSE2, AMD Opteron/Athlon 64+/SSE2,
          or ARM64 (Windows 11 23H2+ only)
        - RAM: 2GB minimum
        - Disk: 5GB minimum, 20GB recommended
        - .NET Framework: version required varies by OS (checked below)
        - Network: outbound TCP/443 to the distribution/management server

    Source for AV coexistence guidance (this is the part most likely to
    cause a "successful" install that doesn't actually protect anything,
    or a broken Windows Security Center state):
      PANW guidance / community threads on Cortex XDR + Microsoft Defender
      coexistence: uninstalling other third-party AV before install is
      recommended; if Defender coexistence is required, configure mutual
      exclusions. Cortex XDR registers with Windows Security Center and
      Windows will auto-disable Defender on CLIENT SKUs -- but NOT on
      Windows Server, where Defender must be disabled/removed manually.

.NOTES
    Run from an elevated (Administrator) PowerShell prompt.

.EXAMPLE
    .\Check-Requirements.ps1
    .\Check-Requirements.ps1 -DistributionServer "https://distributions.traps.paloaltonetworks.com/"
#>

[CmdletBinding()]
param(
    [string]$DistributionServer
)

$pass = 0
$warn = 0
$fail = 0

function Write-Result {
    param([string]$Level, [string]$Message)
    switch ($Level) {
        'PASS' { Write-Host "[PASS] $Message" -ForegroundColor Green; $script:pass++ }
        'WARN' { Write-Host "[WARN] $Message" -ForegroundColor Yellow; $script:warn++ }
        'FAIL' { Write-Host "[FAIL] $Message" -ForegroundColor Red; $script:fail++ }
        'INFO' { Write-Host "[INFO] $Message" }
        'SKIP' { Write-Host "[SKIP] $Message" }
    }
}

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Warning "Not running as Administrator -- some checks (AV product query, disk space on system drive) may be incomplete."
}

$os = Get-CimInstance Win32_OperatingSystem
$cs = Get-CimInstance Win32_ComputerSystem

Write-Host "== Cortex XDR pre-deployment requirements check (Windows) =="
Write-Host "Host: $env:COMPUTERNAME   OS: $($os.Caption) (Build $($os.BuildNumber))   Date: $((Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss')) UTC"
Write-Host "!! DISCLAIMER: not tested against a real Cortex XDR deployment. Pilot before fleet-wide use. !!" -ForegroundColor Yellow
Write-Host ""

# --- OS version -----------------------------------------------------------
Write-Result INFO "OS: $($os.Caption) -- cross-check against PANW's Compatibility Matrix for your agent version"

# --- CPU architecture -------------------------------------------------
$arch = $env:PROCESSOR_ARCHITECTURE
if ($arch -in @('AMD64', 'x86')) {
    Write-Result PASS "CPU architecture supported: $arch"
} elseif ($arch -eq 'ARM64') {
    $buildNum = [int]$os.BuildNumber
    if ($buildNum -ge 22631) {
        Write-Result PASS "CPU architecture ARM64 supported (Windows 11 23H2+, build $buildNum)"
    } else {
        Write-Result FAIL "ARM64 requires Windows 11 23H2 (build 22631) or later -- detected build $buildNum"
    }
} else {
    Write-Result FAIL "Unrecognized/unsupported CPU architecture: $arch"
}

# --- RAM --------------------------------------------------------------
$ramGB = [math]::Round($cs.TotalPhysicalMemory / 1GB, 1)
if ($ramGB -ge 2) {
    Write-Result PASS "RAM: ${ramGB}GB (meets 2GB minimum)"
} else {
    Write-Result FAIL "RAM: ${ramGB}GB (2GB minimum required)"
}

# --- Disk space ---------------------------------------------------------
$sysDrive = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$($env:SystemDrive)'"
$freeGB = [math]::Round($sysDrive.FreeSpace / 1GB, 1)
if ($freeGB -ge 5) {
    if ($freeGB -ge 20) {
        Write-Result PASS "Disk space on $($env:SystemDrive): ${freeGB}GB free (meets 20GB recommended)"
    } else {
        Write-Result WARN "Disk space on $($env:SystemDrive): ${freeGB}GB free (meets 5GB minimum, but 20GB is recommended)"
    }
} else {
    Write-Result FAIL "Disk space on $($env:SystemDrive): ${freeGB}GB free (5GB minimum required)"
}

# --- .NET Framework (requirement varies by OS) -----------------------
try {
    $netRelease = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full' -ErrorAction Stop).Release
    # Release >= 393295 corresponds to .NET Framework 4.6 (see Microsoft's
    # release-key reference table). Older OSes accept an older minimum
    # (see script header) -- this check uses the newest-OS bar (4.6) as a
    # reasonable default; adjust if targeting legacy Server 2008 R2/2012.
    if ($netRelease -ge 393295) {
        Write-Result PASS ".NET Framework 4.6+ present (release $netRelease)"
    } else {
        Write-Result WARN ".NET Framework release $netRelease found -- may be below 4.6; confirm against the minimum for this specific OS (see script header)"
    }
} catch {
    Write-Result FAIL ".NET Framework 4.x not detected via registry -- required version varies by OS, see script header"
}

# --- Network reachability (443 to distribution/management server) ------
if ($DistributionServer) {
    try {
        $uri = [Uri]$DistributionServer
        $result = Test-NetConnection -ComputerName $uri.Host -Port 443 -WarningAction SilentlyContinue
        if ($result.TcpTestSucceeded) {
            Write-Result PASS "Distribution server reachable on TCP/443: $($uri.Host)"
        } else {
            Write-Result WARN "Could not reach $($uri.Host) on TCP/443 (check firewall/proxy)"
        }
    } catch {
        Write-Result WARN "Failed to test connectivity to '$DistributionServer': $($_.Exception.Message)"
    }
} else {
    Write-Result SKIP "Pass -DistributionServer to also test TCP/443 reachability to your distribution server"
}

# --- Conflicting AV products (Security Center) -------------------------
Write-Host ""
Write-Host "-- Existing AV/security products (Windows Security Center) --"
try {
    $avProducts = Get-CimInstance -Namespace "root/SecurityCenter2" -ClassName AntiVirusProduct -ErrorAction Stop
    if ($avProducts) {
        foreach ($av in $avProducts) {
            Write-Result INFO "Registered AV product: $($av.displayName)"
        }
        $nonDefender = $avProducts | Where-Object { $_.displayName -notmatch 'Windows Defender|Microsoft Defender' }
        if ($nonDefender) {
            Write-Result WARN "Non-Defender AV product(s) present -- PANW recommends uninstalling third-party AV before install, or configuring mutual exclusions if coexistence is required"
        } else {
            Write-Result PASS "Only Windows Defender registered -- Windows will auto-disable it on install (client SKUs only; Windows Server requires manually disabling Defender)"
        }
    } else {
        Write-Result INFO "No AV product registered in Security Center"
    }
} catch {
    Write-Result SKIP "Could not query Security Center (common on Windows Server -- AntiVirusProduct class is client-only). If this is a Server SKU, manually confirm Windows Defender is disabled/removed before install."
}

Write-Host ""
Write-Host "== Summary: $pass passed, $warn warned, $fail failed =="
if ($fail -eq 0) {
    Write-Host "Device appears ready for Cortex XDR deployment." -ForegroundColor Green
    exit 0
} else {
    Write-Host "Device is NOT ready -- resolve [FAIL] items above before deploying." -ForegroundColor Red
    exit 1
}
