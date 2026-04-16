#Requires -Modules Az.Monitor, Az.OperationalInsights, Az.VMware

<#
.SYNOPSIS
    Configures Azure Monitor, alerting, and dashboards for an AVS private cloud.

.DESCRIPTION
    Creates a Log Analytics workspace (if not exists), enables diagnostic settings
    (VMwareSyslog + AllMetrics) on the AVS private cloud, creates alert rules for
    CPU / memory / storage at warning (80 %) and critical (90 %) thresholds, sets
    up an action group with email notification, and deploys a VM-performance
    baseline dashboard.

.PARAMETER ResourceGroupName
    Resource group that contains the AVS private cloud.

.PARAMETER WorkspaceName
    Name of the Log Analytics workspace to create or reuse.

.PARAMETER PrivateCloudName
    Name of the AVS private cloud resource.

.PARAMETER Location
    Azure region. Defaults to eastus.

.PARAMETER ActionGroupEmail
    Email address for alert notifications.

.PARAMETER Simulate
    Run in dry-run mode without making changes.

.EXAMPLE
    .\configure-monitoring.ps1 -ResourceGroupName rg-avs -WorkspaceName law-avs `
        -PrivateCloudName pc-avs -ActionGroupEmail ops@contoso.com -Simulate
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory = $true)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $true)]
    [string]$WorkspaceName,

    [Parameter(Mandatory = $true)]
    [string]$PrivateCloudName,

    [Parameter(Mandatory = $false)]
    [string]$Location = "eastus",

    [Parameter(Mandatory = $false)]
    [string]$ActionGroupEmail = "avs-alerts@contoso.com",

    [switch]$Simulate
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Write-Step  { param([string]$Msg) Write-Host "  » $Msg" -ForegroundColor Cyan }
function Write-Ok    { param([string]$Msg) Write-Host "  ✓ $Msg" -ForegroundColor Green }
function Write-Warn  { param([string]$Msg) Write-Host "  ⚠ $Msg" -ForegroundColor Yellow }
function Write-Err   { param([string]$Msg) Write-Host "  ✗ $Msg" -ForegroundColor Red }

$subscriptionId = (Get-AzContext).Subscription.Id
$avsResourceId  = "/subscriptions/$subscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.AVS/privateClouds/$PrivateCloudName"

# ============================================================================
# 1. Log Analytics Workspace
# ============================================================================
Write-Host "`n=== Log Analytics Workspace ===" -ForegroundColor White
Write-Step "Checking for existing workspace '$WorkspaceName'..."

$workspace = Get-AzOperationalInsightsWorkspace `
    -ResourceGroupName $ResourceGroupName `
    -Name $WorkspaceName -ErrorAction SilentlyContinue

if ($workspace) {
    Write-Ok "Workspace '$WorkspaceName' already exists."
} elseif ($Simulate) {
    Write-Warn "[Simulate] Would create workspace '$WorkspaceName' in $Location."
} else {
    Write-Step "Creating workspace '$WorkspaceName'..."
    try {
        $workspace = New-AzOperationalInsightsWorkspace `
            -ResourceGroupName $ResourceGroupName `
            -Name $WorkspaceName `
            -Location $Location `
            -Sku PerGB2018
        Write-Ok "Workspace created."
    } catch {
        Write-Err "Failed to create workspace: $_"
        throw
    }
}

# ============================================================================
# 2. Diagnostic Settings for AVS Private Cloud
# ============================================================================
Write-Host "`n=== Diagnostic Settings ===" -ForegroundColor White
Write-Step "Configuring diagnostics for '$PrivateCloudName'..."

if ($Simulate) {
    Write-Warn "[Simulate] Would create diagnostic setting 'AVS-Diagnostics' (VMwareSyslog + AllMetrics)."
} else {
    try {
        $logSetting = New-AzDiagnosticSettingLogSettingsObject `
            -Enabled $true `
            -CategoryGroup "allLogs"

        $metricSetting = New-AzDiagnosticSettingMetricSettingsObject `
            -Enabled $true `
            -Category "AllMetrics"

        New-AzDiagnosticSetting `
            -ResourceId $avsResourceId `
            -Name "AVS-Diagnostics" `
            -WorkspaceId $workspace.ResourceId `
            -Log $logSetting `
            -Metric $metricSetting | Out-Null

        Write-Ok "Diagnostic settings applied (VMwareSyslog + AllMetrics)."
    } catch {
        Write-Err "Failed to configure diagnostics: $_"
        throw
    }
}

# ============================================================================
# 3. Action Group
# ============================================================================
Write-Host "`n=== Action Group ===" -ForegroundColor White
$actionGroupName = "AVS-Alerts-AG"
Write-Step "Creating action group '$actionGroupName'..."

if ($Simulate) {
    Write-Warn "[Simulate] Would create action group with email: $ActionGroupEmail."
} else {
    try {
        $emailReceiver = New-AzActionGroupEmailReceiverObject `
            -Name "AVS-Ops-Email" `
            -EmailAddress $ActionGroupEmail

        $actionGroup = Set-AzActionGroup `
            -ResourceGroupName $ResourceGroupName `
            -Name $actionGroupName `
            -ShortName "AVSAlerts" `
            -EmailReceiver $emailReceiver

        Write-Ok "Action group created (email: $ActionGroupEmail)."
    } catch {
        Write-Err "Failed to create action group: $_"
        throw
    }
}

# ============================================================================
# 4. Alert Rules — CPU, Memory, Storage (warning 80 %, critical 90 %)
# ============================================================================
Write-Host "`n=== Alert Rules ===" -ForegroundColor White

$alertDefinitions = @(
    @{ Metric = "DiskUsedPercentage";    FriendlyName = "Storage";  WarningThreshold = 80; CriticalThreshold = 90 }
    @{ Metric = "EffectiveCpuAverage";   FriendlyName = "CPU";      WarningThreshold = 80; CriticalThreshold = 90 }
    @{ Metric = "UsageAverage";          FriendlyName = "Memory";   WarningThreshold = 80; CriticalThreshold = 90 }
)

foreach ($alert in $alertDefinitions) {
    foreach ($severity in @(
        @{ Level = "Warning";  Threshold = $alert.WarningThreshold;  SevValue = 2 },
        @{ Level = "Critical"; Threshold = $alert.CriticalThreshold; SevValue = 1 }
    )) {
        $ruleName = "AVS-$($alert.FriendlyName)-$($severity.Level)"
        Write-Step "Creating alert rule '$ruleName' (>= $($severity.Threshold)%)..."

        if ($Simulate) {
            Write-Warn "[Simulate] Would create alert '$ruleName'."
            continue
        }

        try {
            $condition = New-AzMetricAlertRuleV2Criteria `
                -MetricName $alert.Metric `
                -MetricNamespace "Microsoft.AVS/privateClouds" `
                -TimeAggregation Average `
                -Operator GreaterThanOrEqual `
                -Threshold $severity.Threshold

            $actionGroupId = $actionGroup.Id

            Add-AzMetricAlertRuleV2 `
                -ResourceGroupName $ResourceGroupName `
                -Name $ruleName `
                -TargetResourceId $avsResourceId `
                -Condition $condition `
                -ActionGroupId $actionGroupId `
                -Severity $severity.SevValue `
                -WindowSize (New-TimeSpan -Minutes 15) `
                -Frequency (New-TimeSpan -Minutes 5) `
                -Description "Fires when AVS $($alert.FriendlyName) >= $($severity.Threshold)%." | Out-Null

            Write-Ok "Alert '$ruleName' created."
        } catch {
            Write-Err "Failed to create alert '$ruleName': $_"
            throw
        }
    }
}

# ============================================================================
# 5. VM Performance Baseline Dashboard
# ============================================================================
Write-Host "`n=== Performance Dashboard ===" -ForegroundColor White
$dashboardName = "AVS-VM-Performance"
Write-Step "Deploying dashboard '$dashboardName'..."

if ($Simulate) {
    Write-Warn "[Simulate] Would deploy performance dashboard."
} else {
    try {
        $workspaceResourceId = $workspace.ResourceId

        $dashboardProperties = @{
            lenses = @{
                "0" = @{
                    order = 0
                    parts = @{
                        "0" = @{
                            position = @{ x = 0; y = 0; colSpan = 6; rowSpan = 4 }
                            metadata = @{
                                type  = "Extension/Microsoft_OperationsManagementSuite_Workspace/PartType/LogsDashboardPart"
                                inputs = @(
                                    @{ name = "resourceTypeMode"; value = "workspace" }
                                    @{ name = "ComponentId";      value = $workspaceResourceId }
                                )
                                settings = @{
                                    content = @{
                                        Query = @"
Perf
| where ObjectName == "Processor" and CounterName == "% Processor Time"
| summarize AvgCPU = avg(CounterValue) by Computer, bin(TimeGenerated, 5m)
| render timechart
"@
                                        Title = "CPU Utilization by VM"
                                    }
                                }
                            }
                        }
                        "1" = @{
                            position = @{ x = 6; y = 0; colSpan = 6; rowSpan = 4 }
                            metadata = @{
                                type  = "Extension/Microsoft_OperationsManagementSuite_Workspace/PartType/LogsDashboardPart"
                                inputs = @(
                                    @{ name = "resourceTypeMode"; value = "workspace" }
                                    @{ name = "ComponentId";      value = $workspaceResourceId }
                                )
                                settings = @{
                                    content = @{
                                        Query = @"
Perf
| where ObjectName == "Memory" and CounterName == "% Committed Bytes In Use"
| summarize AvgMem = avg(CounterValue) by Computer, bin(TimeGenerated, 5m)
| render timechart
"@
                                        Title = "Memory Utilization by VM"
                                    }
                                }
                            }
                        }
                        "2" = @{
                            position = @{ x = 0; y = 4; colSpan = 6; rowSpan = 4 }
                            metadata = @{
                                type  = "Extension/Microsoft_OperationsManagementSuite_Workspace/PartType/LogsDashboardPart"
                                inputs = @(
                                    @{ name = "resourceTypeMode"; value = "workspace" }
                                    @{ name = "ComponentId";      value = $workspaceResourceId }
                                )
                                settings = @{
                                    content = @{
                                        Query = @"
Perf
| where ObjectName == "LogicalDisk" and CounterName == "% Free Space"
| summarize AvgDisk = avg(CounterValue) by Computer, InstanceName, bin(TimeGenerated, 15m)
| render timechart
"@
                                        Title = "Disk Free Space by VM"
                                    }
                                }
                            }
                        }
                        "3" = @{
                            position = @{ x = 6; y = 4; colSpan = 6; rowSpan = 4 }
                            metadata = @{
                                type  = "Extension/Microsoft_OperationsManagementSuite_Workspace/PartType/LogsDashboardPart"
                                inputs = @(
                                    @{ name = "resourceTypeMode"; value = "workspace" }
                                    @{ name = "ComponentId";      value = $workspaceResourceId }
                                )
                                settings = @{
                                    content = @{
                                        Query = @"
Perf
| where ObjectName == "Network Adapter" and CounterName == "Bytes Total/sec"
| summarize AvgNet = avg(CounterValue) by Computer, bin(TimeGenerated, 5m)
| render timechart
"@
                                        Title = "Network Throughput by VM"
                                    }
                                }
                            }
                        }
                    }
                }
            }
            metadata = @{
                model = @{
                    timeRange = @{
                        type  = "MsPortalFx.Composition.Configuration.ValueTypes.TimeRange"
                        value = @{ relative = @{ duration = 24; timeUnit = 1 } }
                    }
                }
            }
        }

        $dashboardJson = $dashboardProperties | ConvertTo-Json -Depth 20 -Compress
        $dashboardFilePath = [System.IO.Path]::GetTempFileName()
        $dashboardJson | Set-Content -Path $dashboardFilePath -Encoding UTF8

        az portal dashboard create `
            --resource-group $ResourceGroupName `
            --name $dashboardName `
            --location $Location `
            --input-path $dashboardFilePath 2>$null

        if ($LASTEXITCODE -eq 0) {
            Write-Ok "Dashboard '$dashboardName' deployed."
        } else {
            Write-Warn "Dashboard creation via CLI returned non-zero — verify manually in the Azure portal."
        }

        Remove-Item -Path $dashboardFilePath -Force -ErrorAction SilentlyContinue
    } catch {
        Write-Err "Failed to deploy dashboard: $_"
        Write-Warn "You can import the dashboard manually from the Azure portal."
    }
}

# ============================================================================
# Summary
# ============================================================================
Write-Host "`n=== Monitoring Configuration Summary ===" -ForegroundColor White
$summaryItems = @(
    "Log Analytics Workspace : $WorkspaceName"
    "Diagnostic Settings     : AVS-Diagnostics (VMwareSyslog + AllMetrics)"
    "Action Group            : $actionGroupName ($ActionGroupEmail)"
    "Alert Rules             : 6 rules (CPU/Memory/Storage × Warning/Critical)"
    "Dashboard               : $dashboardName (CPU, Memory, Disk, Network)"
)
$summaryItems | ForEach-Object { Write-Host "  $_" -ForegroundColor Gray }

Write-Host "`n✓ Azure Monitor configured successfully!`n" -ForegroundColor Green
