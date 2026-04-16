<#
.SYNOPSIS
    Validates that migrated VMs are running correctly on Azure VMware Solution.

.DESCRIPTION
    Runs comprehensive post-migration validation checks against the Harbor
    Retail VMs after HCX migration to AVS. Checks include:

      - All 5 VMs powered on and responsive
      - IP addresses match expected values
      - VMware Tools running on all VMs
      - Network connectivity between tiers (web→app 8080, app→db 1433)
      - DNS resolution for all VMs
      - IIS responding on web tier VMs
      - API health endpoint responding on app tier
      - SQL Server accepting connections on DB01
      - Load balancer health checks passing

    Outputs a colour-coded console report and a JSON validation report.

.PARAMETER AVSVCenterServer
    AVS vCenter Server FQDN or IP.

.PARAMETER Credential
    PSCredential for AVS vCenter authentication. If omitted with no
    -Simulate flag, the script will prompt.

.PARAMETER NSXTManager
    NSX-T Manager FQDN or IP for network validation.
    Default: 10.0.0.3

.PARAMETER InventoryPath
    Path to the vCenter inventory JSON export.
    Default: ..\..\vmware-config\vcenter-inventory.json

.PARAMETER OutputPath
    Directory for the JSON validation report. Default: .\output

.PARAMETER Simulate
    Run all checks in simulation mode without live AVS calls.

.EXAMPLE
    .\validate-post-migration.ps1 -Simulate
    Validates all VMs using simulated data.

.EXAMPLE
    .\validate-post-migration.ps1 -AVSVCenterServer vcenter.avs.harbor.local `
        -Credential (Get-Credential)
    Validates all VMs against a live AVS vCenter.

.NOTES
    Author  : Harbor Retail Platform Engineering
    Requires: PowerShell 5.1+, VMware PowerCLI 13.0+ (live mode)
    Version : 1.0.0
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$AVSVCenterServer,

    [Parameter(Mandatory = $false)]
    [PSCredential]$Credential,

    [Parameter(Mandatory = $false)]
    [string]$NSXTManager = "10.0.0.3",

    [Parameter(Mandatory = $false)]
    [string]$InventoryPath,

    [Parameter(Mandatory = $false)]
    [string]$OutputPath = ".\output",

    [Parameter(Mandatory = $false)]
    [switch]$Simulate
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ───────────────────────────────────────────────────────────────────────────
# Constants
# ───────────────────────────────────────────────────────────────────────────

$ExpectedVMs = @{
    WEB01 = @{ IP = "10.10.10.11"; Tier = "Web";  FQDN = "web01.harbor.local" }
    WEB02 = @{ IP = "10.10.10.12"; Tier = "Web";  FQDN = "web02.harbor.local" }
    APP01 = @{ IP = "10.10.20.11"; Tier = "App";  FQDN = "app01.harbor.local" }
    APP02 = @{ IP = "10.10.20.12"; Tier = "App";  FQDN = "app02.harbor.local" }
    DB01  = @{ IP = "10.10.30.11"; Tier = "DB";   FQDN = "db01.harbor.local"  }
}

$LoadBalancerVIP = "192.168.1.100"

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
    Write-Host ("  [{0}] {1,-32} {2}" -f $sym, $CheckName, $Detail) -ForegroundColor $colour
}

function Add-CheckResult {
    param(
        [System.Collections.ArrayList]$CheckList,
        [hashtable]$Result,
        [hashtable]$Summary,
        [ref]$VMOverall,
        [ref]$OverallPass
    )
    [void]$CheckList.Add($Result)
    $Summary.Total++
    switch ($Result.Status) {
        "Pass" { $Summary.Pass++ }
        "Fail" { $Summary.Fail++; $VMOverall.Value = "Fail"; $OverallPass.Value = $false }
        "Warn" { $Summary.Warn++ }
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

# Determine execution mode
$liveMode = $false
if ($AVSVCenterServer -and -not $Simulate) {
    $liveMode = $true
    Write-Host "Connecting to AVS vCenter: $AVSVCenterServer" -ForegroundColor Cyan
    if (-not $Credential) {
        $Credential = Get-Credential -Message "Enter AVS vCenter credentials"
    }
    try {
        Connect-VIServer -Server $AVSVCenterServer -Credential $Credential -ErrorAction Stop | Out-Null
    }
    catch {
        Write-Error "Failed to connect to AVS vCenter: $_"
        exit 1
    }
}

if (-not $liveMode) {
    Write-Host "`nRunning in SIMULATION mode — all checks return synthetic pass results.`n" -ForegroundColor Yellow
}

# ───────────────────────────────────────────────────────────────────────────
# Per-check functions
# ───────────────────────────────────────────────────────────────────────────

function Test-VMPoweredOn {
    param([string]$Name, [bool]$Live)
    $result = @{ Check = "VM Powered On"; Status = "Pass"; Detail = "" }

    if ($Live) {
        try {
            $vm = Get-VM -Name $Name -ErrorAction Stop
            if ($vm.PowerState -eq "PoweredOn") {
                $result.Detail = "PoweredOn on AVS"
            } else {
                $result.Status = "Fail"
                $result.Detail = "Power state: $($vm.PowerState)"
            }
        }
        catch {
            $result.Status = "Fail"
            $result.Detail = "VM not found on AVS: $_"
        }
    } else {
        $result.Detail = "PoweredOn on AVS (simulated)"
    }
    return $result
}

function Test-VMResponsive {
    param([string]$Name, [string]$IP, [bool]$Live)
    $result = @{ Check = "VM Responsive (ping)"; Status = "Pass"; Detail = "" }

    if ($Live) {
        try {
            $ping = Test-Connection -ComputerName $IP -Count 3 -Quiet -ErrorAction SilentlyContinue
            if ($ping) {
                $result.Detail = "$IP responding to ICMP"
            } else {
                $result.Status = "Fail"
                $result.Detail = "$IP not responding to ICMP"
            }
        }
        catch {
            $result.Status = "Fail"
            $result.Detail = "Ping failed for $IP`: $_"
        }
    } else {
        $result.Detail = "$IP responding to ICMP (simulated)"
    }
    return $result
}

function Test-IPAddressMatch {
    param([string]$Name, [string]$ExpectedIP, [bool]$Live)
    $result = @{ Check = "IP Address Match"; Status = "Pass"; Detail = "" }

    if ($Live) {
        try {
            $vm = Get-VM -Name $Name -ErrorAction Stop
            $guestIP = $vm.ExtensionData.Guest.IpAddress
            if ($guestIP -eq $ExpectedIP) {
                $result.Detail = "$guestIP matches expected"
            } else {
                $result.Status = "Fail"
                $result.Detail = "Got $guestIP, expected $ExpectedIP"
            }
        }
        catch {
            $result.Status = "Fail"
            $result.Detail = "Could not retrieve IP: $_"
        }
    } else {
        $result.Detail = "$ExpectedIP matches expected (simulated)"
    }
    return $result
}

function Test-VMwareToolsRunning {
    param([string]$Name, [bool]$Live)
    $result = @{ Check = "VMware Tools Running"; Status = "Pass"; Detail = "" }

    if ($Live) {
        try {
            $vm = Get-VM -Name $Name -ErrorAction Stop
            $toolsStatus = $vm.ExtensionData.Guest.ToolsRunningStatus
            if ($toolsStatus -eq "guestToolsRunning") {
                $result.Detail = "Running (version $($vm.ExtensionData.Guest.ToolsVersion))"
            } else {
                $result.Status = "Fail"
                $result.Detail = "Tools status: $toolsStatus"
            }
        }
        catch {
            $result.Status = "Fail"
            $result.Detail = "Error querying VMware Tools: $_"
        }
    } else {
        $result.Detail = "Running (simulated)"
    }
    return $result
}

function Test-TierConnectivity {
    param(
        [string]$SourceName,
        [string]$TargetIP,
        [int]$Port,
        [string]$Description,
        [bool]$Live
    )
    $result = @{ Check = "Connectivity: $Description"; Status = "Pass"; Detail = "" }

    if ($Live) {
        try {
            $tcp = New-Object System.Net.Sockets.TcpClient
            $connectTask = $tcp.ConnectAsync($TargetIP, $Port)
            if ($connectTask.Wait(5000)) {
                if ($tcp.Connected) {
                    $result.Detail = "TCP $Port open on $TargetIP"
                    $tcp.Close()
                } else {
                    $result.Status = "Fail"
                    $result.Detail = "TCP $Port closed on $TargetIP"
                }
            } else {
                $result.Status = "Fail"
                $result.Detail = "TCP $Port connection timed out to $TargetIP"
            }
        }
        catch {
            $result.Status = "Fail"
            $result.Detail = "TCP $Port failed to $TargetIP`: $_"
        }
    } else {
        $result.Detail = "TCP $Port open on $TargetIP (simulated)"
    }
    return $result
}

function Test-DNSResolution {
    param([string]$FQDN, [string]$ExpectedIP, [bool]$Live)
    $result = @{ Check = "DNS Resolution"; Status = "Pass"; Detail = "" }

    if ($Live) {
        try {
            $resolved = Resolve-DnsName -Name $FQDN -Type A -ErrorAction Stop
            $resolvedIP = ($resolved | Where-Object { $_.QueryType -eq 'A' }).IPAddress
            if ($resolvedIP -contains $ExpectedIP) {
                $result.Detail = "$FQDN -> $ExpectedIP"
            } else {
                $result.Status = "Fail"
                $result.Detail = "$FQDN resolved to $($resolvedIP -join ','), expected $ExpectedIP"
            }
        }
        catch {
            $result.Status = "Fail"
            $result.Detail = "DNS lookup failed for $FQDN"
        }
    } else {
        $result.Detail = "$FQDN -> $ExpectedIP (simulated)"
    }
    return $result
}

function Test-IISResponding {
    param([string]$IP, [bool]$Live)
    $result = @{ Check = "IIS Health (/health)"; Status = "Pass"; Detail = "" }

    if ($Live) {
        try {
            $uri = "https://$IP/health"
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
        $result.Detail = "HTTP 200 — https://$IP/health (simulated)"
    }
    return $result
}

function Test-APIHealth {
    param([string]$IP, [bool]$Live)
    $result = @{ Check = "API Health (/health)"; Status = "Pass"; Detail = "" }

    if ($Live) {
        try {
            $uri = "http://${IP}:8080/health"
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
        $result.Detail = "HTTP 200 — http://${IP}:8080/health (simulated)"
    }
    return $result
}

function Test-SQLConnectivity {
    param([string]$IP, [bool]$Live)
    $result = @{ Check = "SQL Server Connectivity"; Status = "Pass"; Detail = "" }

    if ($Live) {
        try {
            $tcp = New-Object System.Net.Sockets.TcpClient
            $connectTask = $tcp.ConnectAsync($IP, 1433)
            if ($connectTask.Wait(5000)) {
                if ($tcp.Connected) {
                    $result.Detail = "TCP 1433 open on $IP"
                    $tcp.Close()
                } else {
                    $result.Status = "Fail"
                    $result.Detail = "TCP 1433 closed on $IP"
                }
            } else {
                $result.Status = "Fail"
                $result.Detail = "TCP 1433 connection timed out to $IP"
            }
        }
        catch {
            $result.Status = "Fail"
            $result.Detail = "SQL connectivity failed on $IP`: $_"
        }
    } else {
        $result.Detail = "TCP 1433 open on $IP (simulated)"
    }
    return $result
}

function Test-LoadBalancerHealth {
    param([string]$VIP, [bool]$Live)
    $result = @{ Check = "Load Balancer Health"; Status = "Pass"; Detail = "" }

    if ($Live) {
        try {
            $uri = "https://$VIP/health"
            $response = Invoke-WebRequest -Uri $uri -UseBasicParsing -TimeoutSec 10 `
                -SkipCertificateCheck -ErrorAction Stop
            if ($response.StatusCode -eq 200) {
                $result.Detail = "HTTP 200 from VIP $VIP"
            } else {
                $result.Status = "Warn"
                $result.Detail = "HTTP $($response.StatusCode) from VIP $VIP"
            }
        }
        catch {
            $result.Status = "Fail"
            $result.Detail = "LB health check failed on $VIP`: $_"
        }
    } else {
        $result.Detail = "HTTP 200 — https://$VIP/health (simulated)"
    }
    return $result
}

# ───────────────────────────────────────────────────────────────────────────
# Main validation loop
# ───────────────────────────────────────────────────────────────────────────

$report = @{
    Timestamp       = (Get-Date).ToString("o")
    Mode            = if ($liveMode) { "Live" } else { "Simulation" }
    ValidationPhase = "Post-Migration"
    VMs             = @()
    CrossTier       = @()
    LoadBalancer    = $null
    Summary         = @{ Total = 0; Pass = 0; Fail = 0; Warn = 0 }
}

$overallPass = $true

foreach ($vmName in ($ExpectedVMs.Keys | Sort-Object)) {
    $vmInfo   = $ExpectedVMs[$vmName]
    $tier     = $vmInfo.Tier
    $ip       = $vmInfo.IP
    $fqdn     = $vmInfo.FQDN

    $vmResults = @{
        Name    = $vmName
        Tier    = $tier
        IP      = $ip
        FQDN    = $fqdn
        Checks  = [System.Collections.ArrayList]::new()
        Overall = "Pass"
    }

    Write-Host "`n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan
    Write-Host "  VM: $vmName  |  Tier: $tier  |  Expected IP: $ip" -ForegroundColor Cyan
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan

    # --- Common checks (all VMs) ---
    $checks = @(
        (Test-VMPoweredOn      -Name $vmName -Live $liveMode),
        (Test-VMResponsive     -Name $vmName -IP $ip -Live $liveMode),
        (Test-IPAddressMatch   -Name $vmName -ExpectedIP $ip -Live $liveMode),
        (Test-VMwareToolsRunning -Name $vmName -Live $liveMode),
        (Test-DNSResolution    -FQDN $fqdn -ExpectedIP $ip -Live $liveMode)
    )

    # --- Tier-specific checks ---
    switch ($tier) {
        'Web' {
            $checks += (Test-IISResponding -IP $ip -Live $liveMode)
        }
        'App' {
            $checks += (Test-APIHealth -IP $ip -Live $liveMode)
        }
        'DB' {
            $checks += (Test-SQLConnectivity -IP $ip -Live $liveMode)
        }
    }

    foreach ($check in $checks) {
        Write-Check -VMName $vmName -CheckName $check.Check `
            -Status $check.Status -Detail $check.Detail
        Add-CheckResult -CheckList $vmResults.Checks -Result $check `
            -Summary $report.Summary -VMOverall ([ref]$vmResults.Overall) `
            -OverallPass ([ref]$overallPass)
    }

    $report.VMs += $vmResults
}

# ───────────────────────────────────────────────────────────────────────────
# Cross-tier connectivity checks
# ───────────────────────────────────────────────────────────────────────────

Write-Host "`n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Magenta
Write-Host "  CROSS-TIER CONNECTIVITY VALIDATION" -ForegroundColor Magenta
Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Magenta

$crossTierChecks = @(
    @{ Source = "WEB01"; TargetIP = "10.10.20.11"; Port = 8080; Desc = "WEB01 -> APP01:8080" },
    @{ Source = "WEB01"; TargetIP = "10.10.20.12"; Port = 8080; Desc = "WEB01 -> APP02:8080" },
    @{ Source = "WEB02"; TargetIP = "10.10.20.11"; Port = 8080; Desc = "WEB02 -> APP01:8080" },
    @{ Source = "WEB02"; TargetIP = "10.10.20.12"; Port = 8080; Desc = "WEB02 -> APP02:8080" },
    @{ Source = "APP01"; TargetIP = "10.10.30.11"; Port = 1433; Desc = "APP01 -> DB01:1433"  },
    @{ Source = "APP02"; TargetIP = "10.10.30.11"; Port = 1433; Desc = "APP02 -> DB01:1433"  }
)

foreach ($ct in $crossTierChecks) {
    $check = Test-TierConnectivity -SourceName $ct.Source -TargetIP $ct.TargetIP `
        -Port $ct.Port -Description $ct.Desc -Live $liveMode
    Write-Check -VMName $ct.Source -CheckName $check.Check `
        -Status $check.Status -Detail $check.Detail

    $ctResult = @{
        Source      = $ct.Source
        Target      = $ct.Desc
        Port        = $ct.Port
        Check       = $check.Check
        Status      = $check.Status
        Detail      = $check.Detail
    }
    $report.CrossTier += $ctResult
    $report.Summary.Total++
    switch ($check.Status) {
        "Pass" { $report.Summary.Pass++ }
        "Fail" { $report.Summary.Fail++; $overallPass = $false }
        "Warn" { $report.Summary.Warn++ }
    }
}

# ───────────────────────────────────────────────────────────────────────────
# Load balancer health check
# ───────────────────────────────────────────────────────────────────────────

Write-Host "`n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Magenta
Write-Host "  LOAD BALANCER VALIDATION (VIP: $LoadBalancerVIP)" -ForegroundColor Magenta
Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Magenta

$lbCheck = Test-LoadBalancerHealth -VIP $LoadBalancerVIP -Live $liveMode
Write-Check -VMName "LB-VIP" -CheckName $lbCheck.Check `
    -Status $lbCheck.Status -Detail $lbCheck.Detail

$report.LoadBalancer = @{
    VIP    = $LoadBalancerVIP
    Check  = $lbCheck.Check
    Status = $lbCheck.Status
    Detail = $lbCheck.Detail
}
$report.Summary.Total++
switch ($lbCheck.Status) {
    "Pass" { $report.Summary.Pass++ }
    "Fail" { $report.Summary.Fail++; $overallPass = $false }
    "Warn" { $report.Summary.Warn++ }
}

# ───────────────────────────────────────────────────────────────────────────
# Summary
# ───────────────────────────────────────────────────────────────────────────

Write-Host "`n╔══════════════════════════════════════════════════╗" -ForegroundColor White
Write-Host "║          POST-MIGRATION VALIDATION SUMMARY       ║" -ForegroundColor White
Write-Host "╚══════════════════════════════════════════════════╝" -ForegroundColor White

Write-Host "`n  Total checks : $($report.Summary.Total)" -ForegroundColor White
Write-Host "  Passed       : $($report.Summary.Pass)" -ForegroundColor Green
Write-Host "  Warnings     : $($report.Summary.Warn)" -ForegroundColor Yellow
Write-Host "  Failed       : $($report.Summary.Fail)" -ForegroundColor Red

Write-Host ""
foreach ($vmr in $report.VMs) {
    $colour = if ($vmr.Overall -eq "Pass") { "Green" } else { "Red" }
    Write-Host ("  {0,-10} {1,-6} {2}" -f $vmr.Name, $vmr.Overall, $vmr.IP) -ForegroundColor $colour
}

$ctPassCount = ($report.CrossTier | Where-Object { $_.Status -eq "Pass" }).Count
$ctTotalCount = $report.CrossTier.Count
Write-Host "`n  Cross-tier   : $ctPassCount/$ctTotalCount passed" -ForegroundColor $(if ($ctPassCount -eq $ctTotalCount) { "Green" } else { "Red" })

$lbColour = if ($report.LoadBalancer.Status -eq "Pass") { "Green" } else { "Red" }
Write-Host "  Load balancer: $($report.LoadBalancer.Status)" -ForegroundColor $lbColour

if ($overallPass) {
    Write-Host "`n  ✔ ALL POST-MIGRATION CHECKS PASSED — application is operational on AVS" -ForegroundColor Green
} else {
    Write-Host "`n  ✘ ONE OR MORE CHECKS FAILED — investigate before declaring migration complete" -ForegroundColor Red
}

# ───────────────────────────────────────────────────────────────────────────
# Export JSON report
# ───────────────────────────────────────────────────────────────────────────

if (-not (Test-Path $OutputPath)) {
    New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
}

$reportFile = Join-Path $OutputPath "post-migration-validation-$(Get-Date -Format 'yyyyMMdd-HHmmss').json"
$report | ConvertTo-Json -Depth 5 | Set-Content -Path $reportFile -Encoding UTF8
Write-Host "`n  Report saved: $reportFile`n" -ForegroundColor Cyan

# ───────────────────────────────────────────────────────────────────────────
# Disconnect vCenter if connected
# ───────────────────────────────────────────────────────────────────────────

if ($liveMode) {
    Disconnect-VIServer -Server $AVSVCenterServer -Confirm:$false -ErrorAction SilentlyContinue
}

# Return exit code for CI/CD integration
if ($overallPass) { exit 0 } else { exit 1 }
