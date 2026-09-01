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

.EXAMPLE
    .\verify-cortex-xdr-install.ps1
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'SilentlyContinue'
$pass = 0
$fail = 0

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
        }
    } catch {
        Write-Host "[FAIL] $Description ($($_.Exception.Message))" -ForegroundColor Red
        $script:fail++
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
    Test-Check "cyserver service is Running" { $svc.Status -eq 'Running' }
    Test-Check "cyserver service StartType is Automatic" { $svc.StartType -eq 'Automatic' }
} else {
    Write-Host "[FAIL] cyserver service not found" -ForegroundColor Red
    $fail++
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
Test-Check "Cortex XDR process running (cyserver.exe)" { (Get-Process -Name "cyserver" -ErrorAction SilentlyContinue) -ne $null }

# 5. cytool status, if present
$cytool = Join-Path $installDir "cytool.exe"
if (Test-Path $cytool) {
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

    # 5b. Distribution ID configured.
    #     CAVEAT: PANW does not publicly document an exact field name/label
    #     for this in cytool's output, so this is a best-effort scan of
    #     `cytool status` + `runtimequery` text for any line mentioning
    #     "distribution", checking it has a non-empty, non-placeholder
    #     value. If your agent version's cytool wording differs, adjust the
    #     regex below to match what you actually see -- don't trust this
    #     blindly without checking real output on a known-good install first.
    Write-Host ""
    Write-Host "-- Distribution ID --"
    try {
        $cytoolStatusOutput = & $cytool status 2>&1
    } catch {
        $cytoolStatusOutput = @()
    }
    $distLine = ($cytoolStatusOutput + $cytoolOutput) | Where-Object { $_ -match 'distribution' } | Select-Object -First 1
    $distValue = ''
    if ($distLine) {
        $distValue = ($distLine -replace '^[^:=]*[:=]\s*', '').Trim()
    }
    if ([string]::IsNullOrWhiteSpace($distValue) -or $distValue -in @('N/A', 'n/a', 'none', '0', 'null', 'unset')) {
        Write-Host "${Bold}[FAIL] No distribution ID appears to be set on this agent.${ResetAnsi}" -ForegroundColor Red
        Write-Host "${Bold}       This installation is UNSUCCESSFUL -- the agent was never told which${ResetAnsi}" -ForegroundColor Red
        Write-Host "${Bold}       tenant to register with. Reinstall with a valid distribution ID.${ResetAnsi}" -ForegroundColor Red
        $fail++
    } else {
        Write-Host "[PASS] Distribution ID appears set: $distLine" -ForegroundColor Green
        $pass++
    }
} else {
    Write-Host "[SKIP] cytool.exe not found at '$cytool' (path may differ by version, or this"
    Write-Host "       script isn't running elevated)."
    Write-Host "[SKIP] Cannot confirm distribution ID without cytool -- re-run as Administrator to check it."
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
    }
} catch {
    Write-Host "[SKIP] Could not query the Windows Event Log"
}

Write-Host ""
Write-Host "== Summary: $pass passed, $fail failed =="

if ($fail -eq 0) {
    Write-Host "Cortex XDR agent looks installed and healthy." -ForegroundColor Green
    exit 0
} else {
    Write-Host "Cortex XDR agent verification found problems - see [FAIL] lines above." -ForegroundColor Red
    exit 1
}
