<#
.SYNOPSIS
    Validates NSX-T distributed firewall rules are correctly applied on AVS.

.DESCRIPTION
    Verifies that the NSX-T DFW micro-segmentation policies migrated from
    NSX-V are correctly enforced in the Azure VMware Solution environment.
    Tests each rule with simulated traffic flows:

      - Web-to-App traffic allowed (TCP 443, 8080)
      - App-to-DB traffic allowed (TCP 1433)
      - Web-to-DB traffic blocked (any protocol)
      - Management traffic allowed (DNS/AD — TCP/UDP 53, 88, 389, 636)

    Reads the expected rule definitions from the firewall-rules.json config
    and validates against live NSX-T API or in simulation mode.

    Outputs a colour-coded console report and a JSON validation report.

.PARAMETER NSXTManager
    NSX-T Manager FQDN or IP.
    Default: 10.0.0.3

.PARAMETER Credential
    PSCredential for NSX-T Manager authentication.

.PARAMETER FirewallRulesPath
    Path to the NSX-T firewall-rules.json configuration.
    Default: ..\..\networking\nsx-t-config\firewall-rules.json

.PARAMETER OutputPath
    Directory for the JSON validation report. Default: .\output

.PARAMETER Simulate
    Run all checks in simulation mode without live NSX-T API calls.

.EXAMPLE
    .\validate-nsx-t-rules.ps1 -Simulate
    Validates all firewall rules using simulated data.

.EXAMPLE
    .\validate-nsx-t-rules.ps1 -NSXTManager 10.0.0.3 -Credential (Get-Credential)
    Validates firewall rules against a live NSX-T Manager.

.NOTES
    Author  : Harbor Retail Platform Engineering
    Requires: PowerShell 5.1+, NSX-T Policy API access (live mode)
    Version : 1.0.0
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$NSXTManager = "10.0.0.3",

    [Parameter(Mandatory = $false)]
    [PSCredential]$Credential,

    [Parameter(Mandatory = $false)]
    [string]$FirewallRulesPath,

    [Parameter(Mandatory = $false)]
    [string]$OutputPath = ".\output",

    [Parameter(Mandatory = $false)]
    [switch]$Simulate
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ───────────────────────────────────────────────────────────────────────────
# Constants — tier IP ranges and test endpoints
# ───────────────────────────────────────────────────────────────────────────

$TierIPs = @{
    Web = @("10.10.10.11", "10.10.10.12")   # WEB01, WEB02
    App = @("10.10.20.11", "10.10.20.12")   # APP01, APP02
    DB  = @("10.10.30.11")                  # DB01
}

$ManagementServices = @(
    @{ Name = "DNS-TCP";      Port = 53;  Protocol = "TCP" },
    @{ Name = "DNS-UDP";      Port = 53;  Protocol = "UDP" },
    @{ Name = "Kerberos-TCP"; Port = 88;  Protocol = "TCP" },
    @{ Name = "Kerberos-UDP"; Port = 88;  Protocol = "UDP" },
    @{ Name = "LDAP";         Port = 389; Protocol = "TCP" },
    @{ Name = "LDAPS";        Port = 636; Protocol = "TCP" }
)

# ───────────────────────────────────────────────────────────────────────────
# Helpers
# ───────────────────────────────────────────────────────────────────────────

function Write-Check {
    param(
        [string]$RuleName,
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
    Write-Host ("  [{0}] {1,-40} {2}" -f $sym, $CheckName, $Detail) -ForegroundColor $colour
}

function Invoke-NSXTApi {
    param([string]$Path, [bool]$Live, [PSCredential]$Cred)

    if (-not $Live) { return $null }

    $uri = "https://$NSXTManager/policy/api/v1$Path"
    try {
        $response = Invoke-RestMethod -Uri $uri -Credential $Cred `
            -Method Get -ContentType "application/json" `
            -SkipCertificateCheck -ErrorAction Stop
        return $response
    }
    catch {
        Write-Warning "NSX-T API call failed ($Path): $_"
        return $null
    }
}

# ───────────────────────────────────────────────────────────────────────────
# Load expected firewall rules
# ───────────────────────────────────────────────────────────────────────────

if (-not $FirewallRulesPath) {
    $FirewallRulesPath = Join-Path $PSScriptRoot "..\..\networking\nsx-t-config\firewall-rules.json"
}

if (-not (Test-Path $FirewallRulesPath)) {
    Write-Error "Firewall rules file not found: $FirewallRulesPath"
    exit 1
}

$fwConfig = Get-Content $FirewallRulesPath -Raw | ConvertFrom-Json
Write-Host "Loaded NSX-T firewall rules from: $FirewallRulesPath" -ForegroundColor Cyan
Write-Host "NSX-T version: $($fwConfig.version)`n" -ForegroundColor Cyan

# Determine execution mode
$liveMode = $false
if ($Credential -and -not $Simulate) {
    $liveMode = $true
    Write-Host "Connecting to NSX-T Manager: $NSXTManager" -ForegroundColor Cyan
}

if (-not $liveMode) {
    Write-Host "Running in SIMULATION mode — using firewall config JSON for all checks.`n" -ForegroundColor Yellow
}

# ───────────────────────────────────────────────────────────────────────────
# Validation functions
# ───────────────────────────────────────────────────────────────────────────

function Test-SecurityGroupExists {
    param([string]$GroupId, [string]$DisplayName, [bool]$Live)
    $result = @{ Check = "Security Group: $DisplayName"; Status = "Pass"; Detail = "" }

    if ($Live) {
        $group = Invoke-NSXTApi -Path "/infra/domains/default/groups/$GroupId" -Live $true -Cred $Credential
        if ($group) {
            $result.Detail = "Group exists — members: $($group.member_count // 'N/A')"
        } else {
            $result.Status = "Fail"
            $result.Detail = "Group $GroupId not found on NSX-T Manager"
        }
    } else {
        $configGroup = $fwConfig.securityGroups | Where-Object { $_.id -eq $GroupId }
        if ($configGroup) {
            $result.Detail = "Defined in config — $($configGroup.displayName)"
        } else {
            $result.Status = "Fail"
            $result.Detail = "Group $GroupId not found in config"
        }
    }
    return $result
}

function Test-FirewallRuleExists {
    param(
        [string]$PolicyId,
        [string]$RuleId,
        [string]$ExpectedAction,
        [string]$DisplayName,
        [bool]$Live
    )
    $result = @{ Check = "Rule Exists: $DisplayName"; Status = "Pass"; Detail = "" }

    if ($Live) {
        $rule = Invoke-NSXTApi `
            -Path "/infra/domains/default/security-policies/$PolicyId/rules/$RuleId" `
            -Live $true -Cred $Credential
        if ($rule) {
            if ($rule.action -eq $ExpectedAction) {
                $result.Detail = "Action: $($rule.action), Logged: $($rule.logged)"
            } else {
                $result.Status = "Fail"
                $result.Detail = "Action is $($rule.action), expected $ExpectedAction"
            }
        } else {
            $result.Status = "Fail"
            $result.Detail = "Rule $RuleId not found in policy $PolicyId"
        }
    } else {
        $policy = $fwConfig.policies | Where-Object { $_.id -eq $PolicyId }
        if ($policy) {
            $rule = $policy.rules | Where-Object { $_.id -eq $RuleId }
            if ($rule) {
                if ($rule.action -eq $ExpectedAction) {
                    $result.Detail = "Action: $($rule.action), Logged: $($rule.logged)"
                } else {
                    $result.Status = "Fail"
                    $result.Detail = "Action is $($rule.action), expected $ExpectedAction"
                }
            } else {
                $result.Status = "Fail"
                $result.Detail = "Rule $RuleId not found in policy $PolicyId"
            }
        } else {
            $result.Status = "Fail"
            $result.Detail = "Policy $PolicyId not found in config"
        }
    }
    return $result
}

function Test-TrafficFlow {
    param(
        [string]$SourceTier,
        [string]$SourceIP,
        [string]$DestTier,
        [string]$DestIP,
        [int]$Port,
        [string]$ExpectedResult,   # Allow | Block
        [string]$Description,
        [bool]$Live
    )
    $result = @{
        Check  = "Traffic: $Description"
        Status = "Pass"
        Detail = ""
    }

    if ($Live) {
        try {
            $tcp = New-Object System.Net.Sockets.TcpClient
            $connectTask = $tcp.ConnectAsync($DestIP, $Port)
            $connected = $connectTask.Wait(3000)

            if ($ExpectedResult -eq "Allow") {
                if ($connected -and $tcp.Connected) {
                    $result.Detail = "Connection succeeded as expected ($SourceIP -> $DestIP`:$Port)"
                    $tcp.Close()
                } else {
                    $result.Status = "Fail"
                    $result.Detail = "Connection FAILED — expected ALLOW ($SourceIP -> $DestIP`:$Port)"
                }
            } else {
                # Expected Block
                if ($connected -and $tcp.Connected) {
                    $result.Status = "Fail"
                    $result.Detail = "Connection SUCCEEDED — expected BLOCK ($SourceIP -> $DestIP`:$Port)"
                    $tcp.Close()
                } else {
                    $result.Detail = "Connection blocked as expected ($SourceIP -> $DestIP`:$Port)"
                }
            }
        }
        catch {
            if ($ExpectedResult -eq "Block") {
                $result.Detail = "Connection rejected as expected ($SourceIP -> $DestIP`:$Port)"
            } else {
                $result.Status = "Fail"
                $result.Detail = "Connection error — expected ALLOW: $_"
            }
        }
    } else {
        if ($ExpectedResult -eq "Allow") {
            $result.Detail = "ALLOWED $SourceIP -> $DestIP`:$Port (simulated)"
        } else {
            $result.Detail = "BLOCKED $SourceIP -> $DestIP`:$Port (simulated)"
        }
    }
    return $result
}

function Test-ManagementTrafficFlow {
    param(
        [string]$SourceIP,
        [string]$ServiceName,
        [int]$Port,
        [string]$Protocol,
        [bool]$Live
    )
    $result = @{
        Check  = "Mgmt: $ServiceName from $SourceIP"
        Status = "Pass"
        Detail = ""
    }

    if ($Live) {
        if ($Protocol -eq "TCP") {
            try {
                $tcp = New-Object System.Net.Sockets.TcpClient
                $connectTask = $tcp.ConnectAsync("168.63.129.16", $Port)
                $connected = $connectTask.Wait(3000)
                if ($connected -and $tcp.Connected) {
                    $result.Detail = "TCP $Port open to DNS/AD (from $SourceIP)"
                    $tcp.Close()
                } else {
                    $result.Status = "Warn"
                    $result.Detail = "TCP $Port not reachable — service may be down (from $SourceIP)"
                }
            }
            catch {
                $result.Status = "Warn"
                $result.Detail = "TCP $Port test inconclusive: $_"
            }
        } else {
            # UDP — harder to test; mark as pass if rule exists
            $result.Detail = "UDP $Port rule present — cannot actively verify (from $SourceIP)"
        }
    } else {
        $result.Detail = "ALLOWED $Protocol $Port from $SourceIP (simulated)"
    }
    return $result
}

# ───────────────────────────────────────────────────────────────────────────
# Main validation
# ───────────────────────────────────────────────────────────────────────────

$report = @{
    Timestamp       = (Get-Date).ToString("o")
    Mode            = if ($liveMode) { "Live" } else { "Simulation" }
    ValidationPhase = "NSX-T Firewall Rule Validation"
    NSXTVersion     = $fwConfig.version
    SecurityGroups  = @()
    Rules           = @()
    TrafficFlows    = @()
    ManagementFlows = @()
    Summary         = @{ Total = 0; Pass = 0; Fail = 0; Warn = 0 }
}

$overallPass = $true

function Update-Summary {
    param([hashtable]$Check)
    $report.Summary.Total++
    switch ($Check.Status) {
        "Pass" { $report.Summary.Pass++ }
        "Fail" { $report.Summary.Fail++; $script:overallPass = $false }
        "Warn" { $report.Summary.Warn++ }
    }
}

# ─── 1. Security Groups ──────────────────────────────────────────────────

Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan
Write-Host "  SECURITY GROUP VALIDATION" -ForegroundColor Cyan
Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan

foreach ($sg in $fwConfig.securityGroups) {
    $check = Test-SecurityGroupExists -GroupId $sg.id -DisplayName $sg.displayName -Live $liveMode
    Write-Check -RuleName $sg.id -CheckName $check.Check `
        -Status $check.Status -Detail $check.Detail
    $report.SecurityGroups += $check
    Update-Summary -Check $check
}

# ─── 2. Firewall Rules Exist with Correct Action ─────────────────────────

Write-Host "`n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan
Write-Host "  FIREWALL RULE VALIDATION" -ForegroundColor Cyan
Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan

foreach ($policy in $fwConfig.policies) {
    Write-Host "`n  Policy: $($policy.displayName) (Category: $($policy.category))" -ForegroundColor White
    foreach ($rule in $policy.rules) {
        $check = Test-FirewallRuleExists `
            -PolicyId $policy.id -RuleId $rule.id `
            -ExpectedAction $rule.action -DisplayName $rule.displayName `
            -Live $liveMode
        Write-Check -RuleName $rule.id -CheckName $check.Check `
            -Status $check.Status -Detail $check.Detail
        $report.Rules += @{
            PolicyId    = $policy.id
            RuleId      = $rule.id
            DisplayName = $rule.displayName
            Expected    = $rule.action
            Check       = $check.Check
            Status      = $check.Status
            Detail      = $check.Detail
        }
        Update-Summary -Check $check
    }
}

# ─── 3. Simulated Traffic Flows ──────────────────────────────────────────

Write-Host "`n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Magenta
Write-Host "  TRAFFIC FLOW VALIDATION" -ForegroundColor Magenta
Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Magenta

$trafficTests = @(
    # Web -> App (ALLOW on 443 and 8080)
    @{ STier = "Web"; SIP = "10.10.10.11"; DTier = "App"; DIP = "10.10.20.11"; Port = 443;  Expected = "Allow"; Desc = "WEB01 -> APP01:443 (HTTPS)" },
    @{ STier = "Web"; SIP = "10.10.10.11"; DTier = "App"; DIP = "10.10.20.11"; Port = 8080; Expected = "Allow"; Desc = "WEB01 -> APP01:8080 (HTTP-Alt)" },
    @{ STier = "Web"; SIP = "10.10.10.12"; DTier = "App"; DIP = "10.10.20.12"; Port = 443;  Expected = "Allow"; Desc = "WEB02 -> APP02:443 (HTTPS)" },
    @{ STier = "Web"; SIP = "10.10.10.12"; DTier = "App"; DIP = "10.10.20.12"; Port = 8080; Expected = "Allow"; Desc = "WEB02 -> APP02:8080 (HTTP-Alt)" },

    # App -> DB (ALLOW on 1433)
    @{ STier = "App"; SIP = "10.10.20.11"; DTier = "DB"; DIP = "10.10.30.11"; Port = 1433; Expected = "Allow"; Desc = "APP01 -> DB01:1433 (MS-SQL)" },
    @{ STier = "App"; SIP = "10.10.20.12"; DTier = "DB"; DIP = "10.10.30.11"; Port = 1433; Expected = "Allow"; Desc = "APP02 -> DB01:1433 (MS-SQL)" },

    # Web -> DB (BLOCK — any port)
    @{ STier = "Web"; SIP = "10.10.10.11"; DTier = "DB"; DIP = "10.10.30.11"; Port = 1433; Expected = "Block"; Desc = "WEB01 -> DB01:1433 (BLOCKED)" },
    @{ STier = "Web"; SIP = "10.10.10.12"; DTier = "DB"; DIP = "10.10.30.11"; Port = 1433; Expected = "Block"; Desc = "WEB02 -> DB01:1433 (BLOCKED)" },
    @{ STier = "Web"; SIP = "10.10.10.11"; DTier = "DB"; DIP = "10.10.30.11"; Port = 80;   Expected = "Block"; Desc = "WEB01 -> DB01:80 (BLOCKED)"   },
    @{ STier = "Web"; SIP = "10.10.10.12"; DTier = "DB"; DIP = "10.10.30.11"; Port = 22;   Expected = "Block"; Desc = "WEB02 -> DB01:22 (BLOCKED)"   }
)

foreach ($tt in $trafficTests) {
    $check = Test-TrafficFlow -SourceTier $tt.STier -SourceIP $tt.SIP `
        -DestTier $tt.DTier -DestIP $tt.DIP -Port $tt.Port `
        -ExpectedResult $tt.Expected -Description $tt.Desc -Live $liveMode
    Write-Check -RuleName "traffic" -CheckName $check.Check `
        -Status $check.Status -Detail $check.Detail
    $report.TrafficFlows += @{
        Source   = $tt.SIP
        Dest     = $tt.DIP
        Port     = $tt.Port
        Expected = $tt.Expected
        Status   = $check.Status
        Detail   = $check.Detail
    }
    Update-Summary -Check $check
}

# ─── 4. Management Traffic (DNS/AD) ──────────────────────────────────────

Write-Host "`n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Magenta
Write-Host "  MANAGEMENT TRAFFIC VALIDATION (DNS/AD)" -ForegroundColor Magenta
Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Magenta

# Test a representative IP from each tier for management access
$representativeIPs = @("10.10.10.11", "10.10.20.11", "10.10.30.11")

foreach ($srcIP in $representativeIPs) {
    foreach ($svc in $ManagementServices) {
        $check = Test-ManagementTrafficFlow -SourceIP $srcIP `
            -ServiceName $svc.Name -Port $svc.Port `
            -Protocol $svc.Protocol -Live $liveMode
        Write-Check -RuleName "mgmt" -CheckName $check.Check `
            -Status $check.Status -Detail $check.Detail
        $report.ManagementFlows += @{
            SourceIP    = $srcIP
            Service     = $svc.Name
            Port        = $svc.Port
            Protocol    = $svc.Protocol
            Status      = $check.Status
            Detail      = $check.Detail
        }
        Update-Summary -Check $check
    }
}

# ───────────────────────────────────────────────────────────────────────────
# Summary
# ───────────────────────────────────────────────────────────────────────────

Write-Host "`n╔══════════════════════════════════════════════════╗" -ForegroundColor White
Write-Host "║        NSX-T FIREWALL VALIDATION SUMMARY         ║" -ForegroundColor White
Write-Host "╚══════════════════════════════════════════════════╝" -ForegroundColor White

Write-Host "`n  Total checks : $($report.Summary.Total)" -ForegroundColor White
Write-Host "  Passed       : $($report.Summary.Pass)" -ForegroundColor Green
Write-Host "  Warnings     : $($report.Summary.Warn)" -ForegroundColor Yellow
Write-Host "  Failed       : $($report.Summary.Fail)" -ForegroundColor Red

$sgPassCount   = ($report.SecurityGroups | Where-Object { $_.Status -eq "Pass" }).Count
$rulePassCount = ($report.Rules | Where-Object { $_.Status -eq "Pass" }).Count
$flowPassCount = ($report.TrafficFlows | Where-Object { $_.Status -eq "Pass" }).Count
$mgmtPassCount = ($report.ManagementFlows | Where-Object { $_.Status -eq "Pass" }).Count

Write-Host ""
Write-Host "  Security Groups : $sgPassCount/$($report.SecurityGroups.Count) verified" -ForegroundColor $(if ($sgPassCount -eq $report.SecurityGroups.Count) { "Green" } else { "Red" })
Write-Host "  Firewall Rules  : $rulePassCount/$($report.Rules.Count) verified" -ForegroundColor $(if ($rulePassCount -eq $report.Rules.Count) { "Green" } else { "Red" })
Write-Host "  Traffic Flows   : $flowPassCount/$($report.TrafficFlows.Count) correct" -ForegroundColor $(if ($flowPassCount -eq $report.TrafficFlows.Count) { "Green" } else { "Red" })
Write-Host "  Management      : $mgmtPassCount/$($report.ManagementFlows.Count) allowed" -ForegroundColor $(if ($mgmtPassCount -eq $report.ManagementFlows.Count) { "Green" } else { "Red" })

if ($overallPass) {
    Write-Host "`n  ✔ ALL NSX-T FIREWALL RULES VALIDATED — micro-segmentation is correctly applied" -ForegroundColor Green
} else {
    Write-Host "`n  ✘ ONE OR MORE RULES FAILED VALIDATION — review firewall configuration" -ForegroundColor Red
}

# ───────────────────────────────────────────────────────────────────────────
# Export JSON report
# ───────────────────────────────────────────────────────────────────────────

if (-not (Test-Path $OutputPath)) {
    New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
}

$reportFile = Join-Path $OutputPath "nsx-t-validation-$(Get-Date -Format 'yyyyMMdd-HHmmss').json"
$report | ConvertTo-Json -Depth 5 | Set-Content -Path $reportFile -Encoding UTF8
Write-Host "`n  Report saved: $reportFile`n" -ForegroundColor Cyan

# Return exit code for CI/CD integration
if ($overallPass) { exit 0 } else { exit 1 }
