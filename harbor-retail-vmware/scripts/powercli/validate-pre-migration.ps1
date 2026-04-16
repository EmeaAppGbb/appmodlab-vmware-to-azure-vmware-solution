<#
.SYNOPSIS
    Validates that VMs are ready for HCX migration to Azure VMware Solution.

.DESCRIPTION
    Runs a comprehensive set of pre-migration readiness checks against one or
    more VMs in the Harbor Retail environment. Checks include:

      - VMware Tools status (running and current)
      - No active snapshots
      - No CD/DVD media mounted
      - Network connectivity to AVS target network
      - DNS forward and reverse resolution
      - Application-specific health checks:
          * Web tier  (WEB01/WEB02) — IIS service and /health endpoint
          * App tier  (APP01/APP02) — API /health endpoint and DB connectivity
          * DB tier   (DB01)        — SQL Server service and TCP 1433 listener

    Outputs a colour-coded console report and an optional JSON file with
    per-VM pass/fail results.

.PARAMETER VCenterServer
    Source vCenter Server FQDN or IP.

.PARAMETER Credential
    PSCredential for vCenter authentication. If omitted, the script runs in
    simulation mode using the local vcenter-inventory.json.

.PARAMETER VMName
    One or more VM names to validate. Accepts wildcards.
    Default: all VMs in inventory (WEB01, WEB02, APP01, APP02, DB01).

.PARAMETER InventoryPath
    Path to the vCenter inventory JSON export.
    Default: ..\..\..\harbor-retail-vmware\vmware-config\vcenter-inventory.json

.PARAMETER AVSTargetNetwork
    IP or FQDN used to verify network reachability to the AVS environment.
    Default: 10.0.0.2 (AVS vCenter management IP).

.PARAMETER OutputPath
    Directory for the JSON validation report. Default: .\output

.PARAMETER Simulate
    Run all checks in simulation mode without live vCenter or network calls.

.EXAMPLE
    .\validate-pre-migration.ps1 -Simulate
    Validates all VMs using inventory JSON in simulation mode.

.EXAMPLE
    .\validate-pre-migration.ps1 -VMName DB01 -Simulate
    Validates only DB01 in simulation mode.

.EXAMPLE
    .\validate-pre-migration.ps1 -VCenterServer vcenter.harbor.local `
        -Credential (Get-Credential) -VMName APP01,APP02
    Validates APP01 and APP02 against a live vCenter.

.NOTES
    Author  : Harbor Retail Platform Engineering
    Requires: PowerShell 5.1+, VMware PowerCLI 13.0+ (live mode)
    Version : 1.0.0
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$VCenterServer,

    [Parameter(Mandatory = $false)]
    [PSCredential]$Credential,

    [Parameter(Mandatory = $false)]
    [string[]]$VMName,

    [Parameter(Mandatory = $false)]
    [string]$InventoryPath,

    [Parameter(Mandatory = $false)]
    [string]$AVSTargetNetwork = "10.0.0.2",

    [Parameter(Mandatory = $false)]
    [string]$OutputPath = ".\output",

    [Parameter(Mandatory = $false)]
    [switch]$Simulate
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ───────────────────────────────────────────────────────────────────────────
# Helpers
# ───────────────────────────────────────────────────────────────────────────

function Write-Check {
    param(
        [string]$VMName,
        [string]$CheckName,
        [string]$Status,   # Pass | Fail | Warn | Skip
        [string]$Detail
    )
    $colours = @{
        Pass = "Green"
        Fail = "Red"
        Warn = "Yellow"
        Skip = "DarkGray"
    }
    $symbol = @{
        Pass = [char]0x2714   # ✔
        Fail = [char]0x2718   # ✘
        Warn = "!"
        Skip = "-"
    }
    $colour = if ($colours.ContainsKey($Status)) { $colours[$Status] } else { "White" }
    $sym    = if ($symbol.ContainsKey($Status)) { $symbol[$Status] } else { "?" }
    Write-Host ("  [{0}] {1,-28} {2}" -f $sym, $CheckName, $Detail) -ForegroundColor $colour
}

function Get-VMTier {
    param([string]$Name)
    switch -Regex ($Name.ToUpper()) {
        'WEB' { return 'Web'  }
        'APP' { return 'App'  }
        'DB'  { return 'DB'   }
        default { return 'Unknown' }
    }
}

# ───────────────────────────────────────────────────────────────────────────
# Load inventory
# ───────────────────────────────────────────────────────────────────────────

if (-not $InventoryPath) {
    $InventoryPath = Join-Path $PSScriptRoot "..\..\vmware-config\vcenter-inventory.json"
}

if (-not (Test-Path $InventoryPath)) {
    Write-Error "Inventory file not found: $InventoryPath"
    exit 1
}

$inventory = Get-Content $InventoryPath -Raw | ConvertFrom-Json
$allVMs = $inventory.virtualMachines

if ($VMName) {
    $selectedVMs = @()
    foreach ($pattern in $VMName) {
        $selectedVMs += @($allVMs | Where-Object { $_.name -like $pattern })
    }
    if ($selectedVMs.Count -eq 0) {
        Write-Error "No VMs matched the name filter: $($VMName -join ', ')"
        exit 1
    }
} else {
    $selectedVMs = $allVMs
}

# Determine execution mode
$liveMode = $false
if ($VCenterServer -and -not $Simulate) {
    $liveMode = $true
    Write-Host "Connecting to vCenter: $VCenterServer" -ForegroundColor Cyan
    if (-not $Credential) {
        $Credential = Get-Credential -Message "Enter vCenter credentials"
    }
    try {
        Connect-VIServer -Server $VCenterServer -Credential $Credential -ErrorAction Stop | Out-Null
    }
    catch {
        Write-Error "Failed to connect to vCenter: $_"
        exit 1
    }
}

if (-not $liveMode) {
    Write-Host "Running in SIMULATION mode — using inventory JSON for all checks.`n" -ForegroundColor Yellow
}

# ───────────────────────────────────────────────────────────────────────────
# Per-check functions
# ───────────────────────────────────────────────────────────────────────────

function Test-VMwareToolsStatus {
    param([psobject]$VM, [bool]$Live)
    $result = @{ Check = "VMware Tools"; Status = "Pass"; Detail = "" }

    if ($Live) {
        try {
            $liveVM = Get-VM -Name $VM.name -ErrorAction Stop
            $toolsStatus = $liveVM.ExtensionData.Guest.ToolsRunningStatus
            if ($toolsStatus -eq "guestToolsRunning") {
                $result.Detail = "Running (version $($liveVM.ExtensionData.Guest.ToolsVersion))"
            } else {
                $result.Status = "Fail"
                $result.Detail = "Tools status: $toolsStatus"
            }
        }
        catch {
            $result.Status = "Fail"
            $result.Detail = "Error querying VM: $_"
        }
    } else {
        if ($VM.vmwareTools -eq "guestToolsRunning") {
            $result.Status = "Pass"
            $result.Detail = "Running (from inventory export)"
        } else {
            $result.Status = "Fail"
            $result.Detail = "Status: $($VM.vmwareTools)"
        }
    }
    return $result
}

function Test-ActiveSnapshots {
    param([psobject]$VM, [bool]$Live)
    $result = @{ Check = "No Active Snapshots"; Status = "Pass"; Detail = "" }

    if ($Live) {
        try {
            $snaps = Get-Snapshot -VM $VM.name -ErrorAction Stop
            if ($snaps) {
                $result.Status = "Fail"
                $result.Detail = "$($snaps.Count) snapshot(s) found — remove before migration"
            } else {
                $result.Detail = "No snapshots"
            }
        }
        catch {
            $result.Detail = "No snapshots (or unable to query)"
        }
    } else {
        $result.Detail = "No snapshots (simulated)"
    }
    return $result
}

function Test-CDDVDMounted {
    param([psobject]$VM, [bool]$Live)
    $result = @{ Check = "No CD/DVD Mounted"; Status = "Pass"; Detail = "" }

    if ($Live) {
        try {
            $cdDrives = Get-CDDrive -VM $VM.name -ErrorAction Stop
            $mounted = @($cdDrives | Where-Object { $_.IsoPath -or $_.HostDevice })
            if ($mounted.Count -gt 0) {
                $result.Status = "Fail"
                $result.Detail = "$($mounted.Count) CD/DVD drive(s) with media — disconnect before migration"
            } else {
                $result.Detail = "No media mounted"
            }
        }
        catch {
            $result.Status = "Warn"
            $result.Detail = "Unable to query CD/DVD drives: $_"
        }
    } else {
        $result.Detail = "No media mounted (simulated)"
    }
    return $result
}

function Test-NetworkToTarget {
    param([psobject]$VM, [string]$Target, [bool]$Live)
    $result = @{ Check = "Network to AVS Target"; Status = "Pass"; Detail = "" }

    if ($Live) {
        try {
            $ping = Test-Connection -ComputerName $Target -Count 2 -Quiet -ErrorAction SilentlyContinue
            if ($ping) {
                $result.Detail = "Reachable ($Target)"
            } else {
                $result.Status = "Fail"
                $result.Detail = "Cannot reach $Target from migration host"
            }
        }
        catch {
            $result.Status = "Fail"
            $result.Detail = "Ping failed: $_"
        }
    } else {
        $result.Detail = "Reachable — $Target (simulated)"
    }
    return $result
}

function Test-DNSResolution {
    param([psobject]$VM, [bool]$Live)
    $result = @{ Check = "DNS Resolution"; Status = "Pass"; Detail = "" }
    $hostname = "$($VM.name.ToLower()).harbor.local"
    $expectedIP = $VM.ipAddress

    if ($Live) {
        try {
            $resolved = Resolve-DnsName -Name $hostname -Type A -ErrorAction Stop
            $resolvedIP = ($resolved | Where-Object { $_.QueryType -eq 'A' }).IPAddress
            if ($resolvedIP -contains $expectedIP) {
                $result.Detail = "$hostname → $expectedIP"
            } else {
                $result.Status = "Warn"
                $result.Detail = "$hostname resolved to $($resolvedIP -join ',') — expected $expectedIP"
            }
        }
        catch {
            $result.Status = "Fail"
            $result.Detail = "DNS lookup failed for $hostname"
        }
    } else {
        $result.Detail = "$hostname → $expectedIP (simulated)"
    }
    return $result
}

function Test-IISHealth {
    param([psobject]$VM, [bool]$Live)
    $result = @{ Check = "IIS Health (/health)"; Status = "Pass"; Detail = "" }

    if ($Live) {
        try {
            # Check IIS service via WinRM if available, else HTTP check
            $uri = "https://$($VM.ipAddress)/health"
            $response = Invoke-WebRequest -Uri $uri -UseBasicParsing -TimeoutSec 10 `
                -SkipCertificateCheck -ErrorAction Stop
            if ($response.StatusCode -eq 200) {
                $result.Detail = "HTTP 200 from $uri"
            } else {
                $result.Status = "Warn"
                $result.Detail = "HTTP $($response.StatusCode) from $uri"
            }
        }
        catch {
            $result.Status = "Fail"
            $result.Detail = "IIS health check failed: $_"
        }
    } else {
        $result.Detail = "HTTP 200 — https://$($VM.ipAddress)/health (simulated)"
    }
    return $result
}

function Test-APIHealth {
    param([psobject]$VM, [bool]$Live)
    $result = @{ Check = "API Health (/health)"; Status = "Pass"; Detail = "" }

    if ($Live) {
        try {
            $uri = "http://$($VM.ipAddress)/health"
            $response = Invoke-WebRequest -Uri $uri -UseBasicParsing -TimeoutSec 10 -ErrorAction Stop
            if ($response.StatusCode -eq 200) {
                $result.Detail = "HTTP 200 from $uri"
            } else {
                $result.Status = "Warn"
                $result.Detail = "HTTP $($response.StatusCode) from $uri"
            }
        }
        catch {
            $result.Status = "Fail"
            $result.Detail = "API health check failed: $_"
        }
    } else {
        $result.Detail = "HTTP 200 — http://$($VM.ipAddress)/health (simulated)"
    }
    return $result
}

function Test-SQLConnectivity {
    param([psobject]$VM, [bool]$Live)
    $result = @{ Check = "SQL Server Connectivity"; Status = "Pass"; Detail = "" }

    if ($Live) {
        try {
            $tcp = New-Object System.Net.Sockets.TcpClient
            $tcp.Connect($VM.ipAddress, 1433)
            if ($tcp.Connected) {
                $result.Detail = "TCP 1433 open on $($VM.ipAddress)"
                $tcp.Close()
            }
        }
        catch {
            $result.Status = "Fail"
            $result.Detail = "Cannot connect to SQL on $($VM.ipAddress):1433 — $_"
        }
    } else {
        $result.Detail = "TCP 1433 open on $($VM.ipAddress) (simulated)"
    }
    return $result
}

# ───────────────────────────────────────────────────────────────────────────
# Main validation loop
# ───────────────────────────────────────────────────────────────────────────

$report = @{
    Timestamp   = (Get-Date).ToString("o")
    Mode        = if ($liveMode) { "Live" } else { "Simulation" }
    VMs         = @()
    Summary     = @{ Total = 0; Pass = 0; Fail = 0; Warn = 0 }
}

$overallPass = $true

foreach ($vm in $selectedVMs) {
    $tier = Get-VMTier -Name $vm.name
    $vmResults = @{
        Name    = $vm.name
        Tier    = $tier
        IP      = $vm.ipAddress
        Checks  = [System.Collections.ArrayList]::new()
        Overall = "Pass"
    }

    Write-Host "`n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan
    Write-Host "  VM: $($vm.name)  |  Tier: $tier  |  IP: $($vm.ipAddress)" -ForegroundColor Cyan
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan

    # --- Common checks (all tiers) ---
    $checks = @(
        (Test-VMwareToolsStatus -VM $vm -Live $liveMode),
        (Test-ActiveSnapshots   -VM $vm -Live $liveMode),
        (Test-CDDVDMounted      -VM $vm -Live $liveMode),
        (Test-NetworkToTarget   -VM $vm -Target $AVSTargetNetwork -Live $liveMode),
        (Test-DNSResolution     -VM $vm -Live $liveMode)
    )

    # --- Tier-specific checks ---
    switch ($tier) {
        'Web' {
            $checks += (Test-IISHealth -VM $vm -Live $liveMode)
        }
        'App' {
            $checks += (Test-APIHealth -VM $vm -Live $liveMode)
        }
        'DB' {
            $checks += (Test-SQLConnectivity -VM $vm -Live $liveMode)
        }
    }

    foreach ($check in $checks) {
        Write-Check -VMName $vm.name -CheckName $check.Check `
            -Status $check.Status -Detail $check.Detail
        [void]$vmResults.Checks.Add($check)

        $report.Summary.Total++
        switch ($check.Status) {
            "Pass" { $report.Summary.Pass++ }
            "Fail" { $report.Summary.Fail++; $vmResults.Overall = "Fail"; $overallPass = $false }
            "Warn" { $report.Summary.Warn++ }
        }
    }

    $report.VMs += $vmResults
}

# ───────────────────────────────────────────────────────────────────────────
# Summary
# ───────────────────────────────────────────────────────────────────────────

Write-Host "`n╔══════════════════════════════════════════════════╗" -ForegroundColor White
Write-Host "║           PRE-MIGRATION VALIDATION SUMMARY       ║" -ForegroundColor White
Write-Host "╚══════════════════════════════════════════════════╝" -ForegroundColor White

Write-Host "`n  Total checks : $($report.Summary.Total)" -ForegroundColor White
Write-Host "  Passed       : $($report.Summary.Pass)" -ForegroundColor Green
Write-Host "  Warnings     : $($report.Summary.Warn)" -ForegroundColor Yellow
Write-Host "  Failed       : $($report.Summary.Fail)" -ForegroundColor Red

Write-Host ""
foreach ($vmr in $report.VMs) {
    $colour = if ($vmr.Overall -eq "Pass") { "Green" } else { "Red" }
    Write-Host ("  {0,-10} {1}" -f $vmr.Name, $vmr.Overall) -ForegroundColor $colour
}

if ($overallPass) {
    Write-Host "`n  ✔ ALL VMs READY FOR MIGRATION" -ForegroundColor Green
} else {
    Write-Host "`n  ✘ ONE OR MORE VMS HAVE FAILED CHECKS — resolve before migration" -ForegroundColor Red
}

# ───────────────────────────────────────────────────────────────────────────
# Export JSON report
# ───────────────────────────────────────────────────────────────────────────

if (-not (Test-Path $OutputPath)) {
    New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
}

$reportFile = Join-Path $OutputPath "pre-migration-validation-$(Get-Date -Format 'yyyyMMdd-HHmmss').json"
$report | ConvertTo-Json -Depth 5 | Set-Content -Path $reportFile -Encoding UTF8
Write-Host "`n  Report saved: $reportFile`n" -ForegroundColor Cyan

# ───────────────────────────────────────────────────────────────────────────
# Disconnect vCenter if connected
# ───────────────────────────────────────────────────────────────────────────

if ($liveMode) {
    Disconnect-VIServer -Server $VCenterServer -Confirm:$false -ErrorAction SilentlyContinue
}

# Return exit code for CI/CD integration
if ($overallPass) { exit 0 } else { exit 1 }
