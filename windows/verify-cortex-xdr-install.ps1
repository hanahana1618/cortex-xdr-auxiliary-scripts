<#
.SYNOPSIS
    Post-install health check for the Palo Alto Networks Cortex XDR
    Windows agent.

    *** UNTESTED: this script has NOT been run against a real Windows  ***
    *** Cortex XDR install. Service/process names and paths were built ***
    *** from Palo Alto Networks' public documentation, not verified    ***
    *** end-to-end on an actual endpoint. Review it and try it on a    ***
    *** non-production machine before relying on its output.           ***

.DESCRIPTION
    Checks the install directory, the Windows service, the running agent
    process, cytool status (if present), and recent log/ProgramData
    activity.

    This is NOT the same script as linux/verify-cortex-xdr-install.sh or
    macos/verify-cortex-xdr-install.sh -- Windows has its own service
    manager (SCM) and install layout entirely, so this is implemented
    natively in PowerShell rather than branched out of the bash scripts.

    Since Cortex XDR agent 7.6 for Windows, "cyserver.exe" is the main
    high-privilege service process, replacing the older CyveraService.exe /
    tlaservice.exe / twdservice.exe processes. The registered service name
    is "cyserver". Related driver/filter services (cyverak, cyvrmtgn,
    cyvrfsfd) may also be present depending on agent version and are
    checked as informational, not required.

.NOTES
    Run from an elevated (Administrator) PowerShell prompt.

    Output ends with a one-line verdict meant to be read on its own, e.g.
    "Cortex XDR is functioning but NOT at full kernel-level capability" or
    "Cortex XDR is NOT functioning -- here are the most important items to
    fix", so you know what action (if any) is needed before reading the
    full report. Exit code 0 = functioning (fully, or degraded-but-
    registered -- read the verdict line to tell which); 1 = not
    functioning, or status couldn't be fully verified (re-run elevated).

.EXAMPLE
    .\verify-cortex-xdr-install.ps1
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'SilentlyContinue'
$pass = 0
$fail = 0
$warn = 0
$failItems = New-Object System.Collections.Generic.List[string]

# State tracked specifically for the one-line verdict at the end.
$serviceOk = $false
$processOk = $false
$checkinStatus = 'unknown'   # unknown | pass | fail
$kernelLevelOk = 'unknown'   # unknown | pass | fail

# ANSI bold, layered on top of Write-Host's -ForegroundColor for terminals
# that support VT escape sequences (Windows Terminal / PowerShell 7+ do by
# default). Falls back to plain red-on-failure if the host doesn't render it.
$Bold = "`e[1m"
$ResetAnsi = "`e[0m"

function Test-Check {
    param(
        [string]$Description,
        [scriptblock]$Test
    )
    try {
        $result = & $Test
        if ($result) {
            Write-Host "[PASS] $Description" -ForegroundColor Green
            $script:pass++
        } else {
            Write-Host "[FAIL] $Description" -ForegroundColor Red
            $script:fail++
            $script:failItems.Add($Description)
        }
    } catch {
        Write-Host "[FAIL] $Description ($($_.Exception.Message))" -ForegroundColor Red
        $script:fail++
        $script:failItems.Add($Description)
    }
}

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Warning "Not running as Administrator -- some checks (cytool, service details) may fail or be incomplete. Re-run from an elevated prompt for full results."
}

Write-Host "== Cortex XDR install verification (Windows) =="
Write-Host "Host: $env:COMPUTERNAME   OS: $((Get-CimInstance Win32_OperatingSystem).Caption)   Date: $((Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss')) UTC"
Write-Host "!! DISCLAIMER: this script has not been tested against a real Cortex XDR install on Windows. !!" -ForegroundColor Yellow
Write-Host "!! Treat its output as a starting point, not a confirmed result.                              !!" -ForegroundColor Yellow
Write-Host ""

# 1. Install directory present
$installDir = "C:\Program Files\Palo Alto Networks\Traps"
Test-Check "Install directory exists ($installDir)" { Test-Path $installDir }

# 2. ProgramData present (config/logs live here)
$dataDir = "C:\ProgramData\Cyvera"
Test-Check "Data directory exists ($dataDir)" { Test-Path $dataDir }

# 3. Main service: cyserver
Write-Host ""
Write-Host "-- Service status --"
$svc = Get-Service -Name "cyserver" -ErrorAction SilentlyContinue
if ($svc) {
    if ($svc.Status -eq 'Running') {
        Write-Host "[PASS] cyserver service is Running" -ForegroundColor Green
        $pass++
        $serviceOk = $true
    } else {
        Write-Host "[FAIL] cyserver service is Running" -ForegroundColor Red
        $fail++
        $failItems.Add("cyserver service is not Running (status: $($svc.Status))")
    }
    Test-Check "cyserver service StartType is Automatic" { $svc.StartType -eq 'Automatic' }
} else {
    Write-Host "[FAIL] cyserver service not found" -ForegroundColor Red
    $fail++
    $failItems.Add("cyserver service not found (agent not installed?)")
}

# Related driver/filter services -- informational only, presence/names
# vary by agent version, so these are not treated as hard failures.
foreach ($svcName in @('cyverak', 'cyvrmtgn', 'cyvrfsfd')) {
    $related = Get-Service -Name $svcName -ErrorAction SilentlyContinue
    if ($related) {
        Write-Host "[INFO] Related service '$svcName' status: $($related.Status)"
    } else {
        Write-Host "[SKIP] Related service '$svcName' not present (may not apply to this agent version)"
    }
}

# 4. Agent process running
Write-Host ""
if ((Get-Process -Name "cyserver" -ErrorAction SilentlyContinue)) {
    Write-Host "[PASS] Cortex XDR process running (cyserver.exe)" -ForegroundColor Green
    $pass++
    $processOk = $true
} else {
    Write-Host "[FAIL] Cortex XDR process running (cyserver.exe)" -ForegroundColor Red
    $fail++
    $failItems.Add("no cyserver.exe process running")
}

# 5. cytool status, if present
$cytool = Join-Path $installDir "cytool.exe"
if (Test-Path $cytool) {
    Write-Host ""
    Write-Host "-- cytool status --"
    try {
        $cytoolStatusOutput = & $cytool status 2>&1
    } catch {
        $cytoolStatusOutput = @()
    }
    $cytoolStatusOutput | ForEach-Object { Write-Host "  $_" }
    Write-Host ""
    Write-Host "-- cytool runtimequery --"
    try {
        $cytoolOutput = & $cytool runtimequery 2>&1
        $cytoolOutput | ForEach-Object { Write-Host "  $_" }
        Test-Check "cytool reports agent status" { $LASTEXITCODE -eq 0 }
    } catch {
        Write-Host "[FAIL] Failed to run cytool ($($_.Exception.Message))" -ForegroundColor Red
        $fail++
    }

    # 5b. Tenant check-in evidence.
    #     Confirmed (via real Linux agent output) that `cytool status`
    #     prints a "Last Successful Check-In time" field -- this is the
    #     actual, reliable signal that the agent has successfully talked
    #     to the tenant. An earlier version of this check instead grepped
    #     for a "distribution ID" line, which real-world testing showed
    #     cytool doesn't print at all on a working, checked-in agent
    #     (false FAIL).
    #     CAVEAT: this exact field wording is confirmed on Linux; it's
    #     expected (cytool is shared across platforms) but NOT
    #     independently confirmed on Windows -- verify against real output
    #     here and adjust if this agent version phrases it differently.
    Write-Host ""
    Write-Host "-- Tenant check-in --"
    $checkinLine = $cytoolStatusOutput | Where-Object { $_ -match 'Successful Check-In time \(UTC\)' } | Select-Object -First 1
    $checkinValue = ''
    if ($checkinLine) {
        $checkinValue = ($checkinLine -replace '^[^:]*\(UTC\):\s*', '').Trim()
    }
    if (-not $checkinLine) {
        Write-Host "${Bold}[FAIL] No 'Last Successful Check-In' field found in cytool status output.${ResetAnsi}" -ForegroundColor Red
        Write-Host "${Bold}       Cannot confirm this agent has ever reached the tenant -- treating this${ResetAnsi}" -ForegroundColor Red
        Write-Host "${Bold}       installation as UNSUCCESSFUL. (cytool's output format may differ by${ResetAnsi}" -ForegroundColor Red
        Write-Host "${Bold}       agent version -- check the raw output above if this looks wrong.)${ResetAnsi}" -ForegroundColor Red
        $fail++
        $failItems.Add("no 'Last Successful Check-In' field in cytool output")
        $checkinStatus = 'fail'
    } elseif ([string]::IsNullOrWhiteSpace($checkinValue) -or $checkinValue -match '^(?i)never$') {
        Write-Host "${Bold}[FAIL] Last Successful Check-In is empty/'Never' -- this agent has NOT${ResetAnsi}" -ForegroundColor Red
        Write-Host "${Bold}       registered/checked in with the tenant. Installation is UNSUCCESSFUL.${ResetAnsi}" -ForegroundColor Red
        $fail++
        $failItems.Add("agent has never checked in with the tenant")
        $checkinStatus = 'fail'
    } else {
        Write-Host "[PASS] Last successful check-in: $checkinValue" -ForegroundColor Green
        $pass++
        $checkinStatus = 'pass'
    }

    # 5c. Kernel-level capability, inferred from cytool's own wording.
    #     CAVEAT: "Kernel Not Supported" is CONFIRMED real wording from a
    #     real Linux agent's `cytool status` output (Operational Status
    #     section, e.g. "Anti Malware : Kernel Not Supported"), not
    #     independently confirmed on Windows. cytool is a shared binary
    #     across platforms so this is a reasonable best-effort port, but
    #     verify against the raw output above if this looks wrong.
    $kernelNotSupported = $cytoolStatusOutput | Where-Object { $_ -match 'Kernel Not Supported' }
    if ($kernelNotSupported) {
        Write-Host "[INFO] cytool reports 'Kernel Not Supported' for one or more capabilities (see raw"
        Write-Host "       output above) -- some kernel-dependent protections are degraded/unavailable."
        $kernelLevelOk = 'fail'
    } elseif ($cytoolStatusOutput) {
        $kernelLevelOk = 'pass'
    }
} else {
    Write-Host "[SKIP] cytool.exe not found at '$cytool' (path may differ by version, or this"
    Write-Host "       script isn't running elevated)."
    Write-Host "[SKIP] Cannot confirm tenant check-in without cytool -- re-run as Administrator to check it."
}

# 6. Recent log/data activity
Write-Host ""
if (Test-Path $dataDir) {
    $recent = Get-ChildItem -Path $dataDir -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -gt (Get-Date).AddMinutes(-5) }
    if ($recent.Count -gt 0) {
        Write-Host "[PASS] Recent file activity in $dataDir (last 5 min, $($recent.Count) file(s))" -ForegroundColor Green
        $pass++
    } else {
        Write-Host "[WARN] No recent file activity in $dataDir in the last 5 minutes (may be normal if idle)" -ForegroundColor Yellow
        $warn++
    }
} else {
    Write-Host "[SKIP] $dataDir not found"
}

# 7. Recent relevant Windows Event Log entries (Application log, PAN/Cortex/Traps source)
try {
    $events = Get-WinEvent -FilterHashtable @{ LogName = 'Application'; StartTime = (Get-Date).AddMinutes(-30) } -ErrorAction SilentlyContinue |
        Where-Object { $_.ProviderName -match 'PanOS|Cortex|Traps|Cyvera' }
    if ($events) {
        Write-Host "[PASS] Found $($events.Count) related event(s) in the Application log (last 30 min)" -ForegroundColor Green
        $pass++
    } else {
        Write-Host "[WARN] No related Application-log events found in the last 30 minutes" -ForegroundColor Yellow
        $warn++
    }
} catch {
    Write-Host "[SKIP] Could not query the Windows Event Log"
}

Write-Host ""
Write-Host "== Summary: $pass passed, $warn warned, $fail failed =="
Write-Host ""

# ---------------------------------------------------------------------------
# One-line verdict, meant to be read on its own before the rest of the
# report. Priority order matters: "is it running at all" beats "is it
# registered" beats "is it at full kernel-level capability".
# ---------------------------------------------------------------------------
$exitCode = 0
if ((-not $isAdmin) -and $checkinStatus -eq 'unknown') {
    Write-Host "${Bold}❓ CANNOT FULLY VERIFY: re-run this script as Administrator for a definitive answer.${ResetAnsi}"
    Write-Host "   (cytool and several other checks need elevation -- results above are incomplete without it.)"
    $exitCode = 1
} elseif ((-not $serviceOk) -or (-not $processOk)) {
    Write-Host "${Bold}❌ Cortex XDR is NOT functioning -- the agent isn't running on this machine.${ResetAnsi}" -ForegroundColor Red
    Write-Host "   Most important items to fix:"
    foreach ($item in $failItems) { Write-Host "     - $item" }
    $exitCode = 1
} elseif ($checkinStatus -eq 'fail') {
    Write-Host "${Bold}❌ Cortex XDR is NOT functioning -- it's running locally but has never${ResetAnsi}" -ForegroundColor Red
    Write-Host "${Bold}   registered/checked in with your tenant.${ResetAnsi}" -ForegroundColor Red
    Write-Host "   Most important items to fix:"
    foreach ($item in $failItems) { Write-Host "     - $item" }
    $exitCode = 1
} elseif ($kernelLevelOk -eq 'fail') {
    Write-Host "${Bold}⚠️  Cortex XDR is functioning, but NOT at full kernel-level capability${ResetAnsi}"
    Write-Host "   (cytool reports 'Kernel Not Supported' for some capabilities -- see raw output above)."
    Write-Host "   Registered and checked in with the tenant, though. Likely fix: enable BPF/User Space"
    Write-Host "   fallback in this endpoint's Agent Settings Profile in the console."
    $exitCode = 0
} elseif ($fail -gt 0) {
    Write-Host "${Bold}❌ Cortex XDR has problems beyond the core checks -- see [FAIL] lines above.${ResetAnsi}" -ForegroundColor Red
    Write-Host "   Most important items to fix:"
    foreach ($item in $failItems) { Write-Host "     - $item" }
    $exitCode = 1
} elseif ($warn -gt 0) {
    Write-Host "${Bold}✅ Cortex XDR is functioning${ResetAnsi}, with $warn minor item(s) worth a look -- see [WARN] lines above." -ForegroundColor Green
    $exitCode = 0
} else {
    Write-Host "${Bold}✅ Cortex XDR is fully functioning, no issues detected.${ResetAnsi}" -ForegroundColor Green
    $exitCode = 0
}

exit $exitCode
