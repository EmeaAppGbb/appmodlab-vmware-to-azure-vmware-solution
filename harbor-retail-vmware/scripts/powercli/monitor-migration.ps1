<#
.SYNOPSIS
    Monitors active HCX migrations with a dashboard-style console display.

.DESCRIPTION
    Provides real-time monitoring of HCX migrations for the Harbor Retail
    VMware-to-AVS migration. Displays a dashboard with:

      - VM name and migration method (Bulk Migration / vMotion)
      - Progress percentage with visual progress bar
      - Data transferred vs total
      - Estimated completion time
      - Current status and phase

    In -Simulate mode, generates realistic migration progress data for all
    five Harbor Retail VMs across three waves.

    The dashboard refreshes at a configurable interval and produces a JSON
    status snapshot on each refresh.

.PARAMETER HCXServer
    HCX Manager FQDN or IP for querying active migrations.

.PARAMETER Credential
    PSCredential for HCX authentication.

.PARAMETER InventoryPath
    Path to vcenter-inventory.json for VM metadata.
    Default: ..\..\vmware-config\vcenter-inventory.json

.PARAMETER OutputPath
    Directory for JSON status snapshots. Default: .\output

.PARAMETER Simulate
    Display simulated migration progress for all Harbor Retail VMs.

.PARAMETER RefreshIntervalSeconds
    Dashboard refresh interval in seconds. Default: 5.

.PARAMETER MaxRefreshes
    Maximum number of refresh cycles before exiting. Default: 0 (unlimited).
    In Simulate mode defaults to completing all simulated migrations.

.PARAMETER WaveFilter
    Show only migrations for specific wave numbers (1, 2, 3).

.EXAMPLE
    .\monitor-migration.ps1 -Simulate
    Displays a simulated migration dashboard for all waves.

.EXAMPLE
    .\monitor-migration.ps1 -Simulate -WaveFilter 1
    Displays simulated progress for Wave 1 (DB01) only.

.EXAMPLE
    .\monitor-migration.ps1 -HCXServer hcx.harbor.local -Credential (Get-Credential)
    Monitors live HCX migrations from the HCX Manager.

.NOTES
    Author  : Harbor Retail Platform Engineering
    Requires: PowerShell 5.1+, VMware HCX PowerCLI (live mode)
    Version : 1.0.0
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$HCXServer = "hcx.harbor.local",

    [Parameter(Mandatory = $false)]
    [PSCredential]$Credential,

    [Parameter(Mandatory = $false)]
    [string]$InventoryPath,

    [Parameter(Mandatory = $false)]
    [string]$OutputPath = ".\output",

    [Parameter(Mandatory = $false)]
    [switch]$Simulate,

    [Parameter(Mandatory = $false)]
    [ValidateRange(1, 300)]
    [int]$RefreshIntervalSeconds = 5,

    [Parameter(Mandatory = $false)]
    [int]$MaxRefreshes = 0,

    [Parameter(Mandatory = $false)]
    [ValidateRange(1, 3)]
    [int[]]$WaveFilter
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ─────────────────────────────────────────────────────────────────────────────
# Load inventory
# ─────────────────────────────────────────────────────────────────────────────

if (-not $InventoryPath) {
    $InventoryPath = Join-Path $PSScriptRoot "..\..\vmware-config\vcenter-inventory.json"
}

if (-not (Test-Path $InventoryPath)) {
    Write-Error "Inventory file not found: $InventoryPath"
    exit 1
}

$inventory = Get-Content $InventoryPath -Raw | ConvertFrom-Json
$allVMs = $inventory.virtualMachines

if (-not $Simulate -and -not $Credential) {
    Write-Host "No credential provided — switching to SIMULATION mode.`n" -ForegroundColor Yellow
    $Simulate = [switch]::new($true)
}

# Ensure output directory
if (-not (Test-Path $OutputPath)) {
    New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
}

# ─────────────────────────────────────────────────────────────────────────────
# Dashboard rendering helpers
# ─────────────────────────────────────────────────────────────────────────────

function Format-DataSize {
    param([double]$GB)
    if ($GB -ge 1024) { return "{0:N1} TB" -f ($GB / 1024) }
    elseif ($GB -ge 1) { return "{0:N1} GB" -f $GB }
    else { return "{0:N0} MB" -f ($GB * 1024) }
}

function Format-Duration {
    param([int]$TotalSeconds)
    if ($TotalSeconds -le 0) { return "—" }
    $h = [math]::Floor($TotalSeconds / 3600)
    $m = [math]::Floor(($TotalSeconds % 3600) / 60)
    $s = $TotalSeconds % 60
    if ($h -gt 0) { return "{0}h {1:D2}m {2:D2}s" -f $h, $m, $s }
    elseif ($m -gt 0) { return "{0}m {1:D2}s" -f $m, $s }
    else { return "{0}s" -f $s }
}

function Get-ProgressBar {
    param([int]$Percent, [int]$Width = 30)
    $filled = [math]::Floor($Width * $Percent / 100)
    $empty = $Width - $filled
    return ("█" * $filled) + ("░" * $empty)
}

function Get-StatusColor {
    param([string]$Status)
    switch ($Status) {
        "Completed"  { return "Green" }
        "InProgress" { return "Cyan" }
        "Pending"    { return "DarkGray" }
        "Failed"     { return "Red" }
        "Queued"     { return "Yellow" }
        default      { return "White" }
    }
}

function Write-DashboardHeader {
    param([string]$Mode, [int]$RefreshCount, [string]$Elapsed)

    Clear-Host
    Write-Host ""
    Write-Host "╔══════════════════════════════════════════════════════════════════════════════╗" -ForegroundColor White
    Write-Host "║               HARBOR RETAIL — HCX MIGRATION MONITOR                        ║" -ForegroundColor White
    Write-Host "╚══════════════════════════════════════════════════════════════════════════════╝" -ForegroundColor White
    Write-Host ""
    Write-Host "  Mode: " -NoNewline -ForegroundColor Gray
    Write-Host "$Mode" -NoNewline -ForegroundColor $(if ($Mode -eq "SIMULATION") { "Yellow" } else { "Green" })
    Write-Host "  |  HCX Manager: " -NoNewline -ForegroundColor Gray
    Write-Host "$HCXServer" -NoNewline -ForegroundColor Cyan
    Write-Host "  |  Elapsed: " -NoNewline -ForegroundColor Gray
    Write-Host "$Elapsed" -ForegroundColor White
    Write-Host "  Refresh #$RefreshCount  |  Interval: ${RefreshIntervalSeconds}s  |  $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor DarkGray
    Write-Host ""
}

function Write-WaveSeparator {
    param([int]$WaveNum, [string]$WaveName, [string]$Method)
    Write-Host "  ┌─── Wave $WaveNum : $WaveName ($Method) ────────────────────────────────────┐" -ForegroundColor Magenta
}

function Write-MigrationRow {
    param([hashtable]$Migration)

    $bar = Get-ProgressBar -Percent $Migration.Percent -Width 25
    $color = Get-StatusColor -Status $Migration.Status
    $transferred = Format-DataSize -GB $Migration.DataTransferredGB
    $total = Format-DataSize -GB $Migration.DataTotalGB
    $eta = Format-Duration -TotalSeconds $Migration.ETASeconds

    Write-Host "  │ " -NoNewline -ForegroundColor Magenta
    Write-Host ("{0,-8}" -f $Migration.VMName) -NoNewline -ForegroundColor White
    Write-Host " [$bar] " -NoNewline -ForegroundColor $color
    Write-Host ("{0,3}%" -f $Migration.Percent) -NoNewline -ForegroundColor $color
    Write-Host " │ " -NoNewline -ForegroundColor DarkGray
    Write-Host ("{0,9}/{1,-9}" -f $transferred, $total) -NoNewline -ForegroundColor Gray
    Write-Host " │ ETA: " -NoNewline -ForegroundColor DarkGray
    Write-Host ("{0,-10}" -f $eta) -NoNewline -ForegroundColor Yellow
    Write-Host " │ " -NoNewline -ForegroundColor DarkGray
    Write-Host ("{0,-12}" -f $Migration.Status) -ForegroundColor $color
}

function Write-PhaseDetail {
    param([string]$Phase)
    Write-Host "  │   └─ " -NoNewline -ForegroundColor DarkGray
    Write-Host "$Phase" -ForegroundColor DarkCyan
}

function Write-WaveFooter {
    Write-Host "  └──────────────────────────────────────────────────────────────────────────┘" -ForegroundColor Magenta
    Write-Host ""
}

function Write-OverallSummary {
    param(
        [int]$TotalVMs,
        [int]$Completed,
        [int]$InProgress,
        [int]$Pending,
        [int]$Failed,
        [double]$TotalDataGB,
        [double]$TransferredDataGB
    )

    $overallPct = if ($TotalDataGB -gt 0) { [math]::Round(($TransferredDataGB / $TotalDataGB) * 100) } else { 0 }
    $bar = Get-ProgressBar -Percent $overallPct -Width 40

    Write-Host "  ╔══════════════════════════════════════════════════════════════════════════╗" -ForegroundColor White
    Write-Host "  ║  OVERALL PROGRESS                                                      ║" -ForegroundColor White
    Write-Host "  ╠══════════════════════════════════════════════════════════════════════════╣" -ForegroundColor White
    Write-Host "  ║  [$bar] $($overallPct)%" -ForegroundColor Cyan
    Write-Host "  ║" -ForegroundColor White
    Write-Host "  ║  VMs: " -NoNewline -ForegroundColor White
    Write-Host "$Completed completed" -NoNewline -ForegroundColor Green
    Write-Host " | " -NoNewline -ForegroundColor DarkGray
    Write-Host "$InProgress in progress" -NoNewline -ForegroundColor Cyan
    Write-Host " | " -NoNewline -ForegroundColor DarkGray
    Write-Host "$Pending pending" -NoNewline -ForegroundColor DarkGray
    Write-Host " | " -NoNewline -ForegroundColor DarkGray
    Write-Host "$Failed failed" -ForegroundColor $(if ($Failed -gt 0) { "Red" } else { "DarkGray" })
    Write-Host ("  ║  Data: {0} / {1}" -f (Format-DataSize $TransferredDataGB), (Format-DataSize $TotalDataGB)) -ForegroundColor Gray
    Write-Host "  ╚══════════════════════════════════════════════════════════════════════════╝" -ForegroundColor White
    Write-Host ""
}

# ─────────────────────────────────────────────────────────────────────────────
# Simulated migration state engine
# ─────────────────────────────────────────────────────────────────────────────

function New-SimulatedMigrationState {
    param([array]$VMs)

    $migrations = @(
        @{
            VMName            = "DB01"
            Wave              = 1
            WaveName          = "Database Tier"
            Method            = "BulkMigration"
            MigrationId       = "HCX-BULK-" + [guid]::NewGuid().ToString().Substring(0, 8).ToUpper()
            Status            = "Queued"
            Percent           = 0
            DataTransferredGB = 0.0
            DataTotalGB       = 320.0
            ETASeconds        = 7200
            Phase             = "Waiting to start"
            StartTime         = $null
            # Simulation: ~18 ticks to complete (each tick is a refresh cycle)
            TickRate          = 6.0
            WaveOrder         = 1
        },
        @{
            VMName            = "APP01"
            Wave              = 2
            WaveName          = "Application Tier"
            Method            = "vMotion"
            MigrationId       = "HCX-VMOT-" + [guid]::NewGuid().ToString().Substring(0, 8).ToUpper()
            Status            = "Pending"
            Percent           = 0
            DataTransferredGB = 0.0
            DataTotalGB       = 120.0
            ETASeconds        = 1800
            Phase             = "Waiting for Wave 1"
            StartTime         = $null
            TickRate          = 8.0
            WaveOrder         = 2
        },
        @{
            VMName            = "APP02"
            Wave              = 2
            WaveName          = "Application Tier"
            Method            = "vMotion"
            MigrationId       = "HCX-VMOT-" + [guid]::NewGuid().ToString().Substring(0, 8).ToUpper()
            Status            = "Pending"
            Percent           = 0
            DataTransferredGB = 0.0
            DataTotalGB       = 118.0
            ETASeconds        = 1800
            Phase             = "Waiting for Wave 1"
            StartTime         = $null
            TickRate          = 8.5
            WaveOrder         = 2
        },
        @{
            VMName            = "WEB01"
            Wave              = 3
            WaveName          = "Web Tier"
            Method            = "vMotion"
            MigrationId       = "HCX-VMOT-" + [guid]::NewGuid().ToString().Substring(0, 8).ToUpper()
            Status            = "Pending"
            Percent           = 0
            DataTransferredGB = 0.0
            DataTotalGB       = 45.0
            ETASeconds        = 1200
            Phase             = "Waiting for Wave 2"
            StartTime         = $null
            TickRate          = 12.0
            WaveOrder         = 3
        },
        @{
            VMName            = "WEB02"
            Wave              = 3
            WaveName          = "Web Tier"
            Method            = "vMotion"
            MigrationId       = "HCX-VMOT-" + [guid]::NewGuid().ToString().Substring(0, 8).ToUpper()
            Status            = "Pending"
            Percent           = 0
            DataTransferredGB = 0.0
            DataTotalGB       = 43.0
            ETASeconds        = 1200
            Phase             = "Waiting for Wave 2"
            StartTime         = $null
            TickRate          = 13.0
            WaveOrder         = 3
        }
    )

    if ($WaveFilter) {
        $migrations = @($migrations | Where-Object { $_.Wave -in $WaveFilter })
    }

    return $migrations
}

function Get-SimulatedPhase {
    param([int]$Percent, [string]$Method)

    if ($Method -eq "BulkMigration") {
        if ($Percent -lt 5)   { return "Initializing bulk migration task" }
        if ($Percent -lt 10)  { return "Validating source VM configuration" }
        if ($Percent -lt 15)  { return "Creating destination placeholder VM" }
        if ($Percent -lt 20)  { return "Configuring HCX network extension" }
        if ($Percent -lt 30)  { return "Starting initial seed replication" }
        if ($Percent -lt 50)  { return "Replicating disk 1 — OS volume" }
        if ($Percent -lt 70)  { return "Replicating disk 2 — Data volume" }
        if ($Percent -lt 78)  { return "Delta sync — changed blocks" }
        if ($Percent -lt 85)  { return "Quiescing source VM for cutover" }
        if ($Percent -lt 90)  { return "Final delta replication" }
        if ($Percent -lt 95)  { return "Switching over to destination" }
        if ($Percent -lt 98)  { return "Powering on VM at destination" }
        if ($Percent -lt 100) { return "Verifying VMware Tools heartbeat" }
        return "Migration completed"
    }
    else {
        if ($Percent -lt 5)   { return "Initializing vMotion task" }
        if ($Percent -lt 15)  { return "Validating source VM" }
        if ($Percent -lt 30)  { return "Pre-copying memory pages (round 1)" }
        if ($Percent -lt 45)  { return "Pre-copying memory pages (round 2)" }
        if ($Percent -lt 65)  { return "Transferring disk state" }
        if ($Percent -lt 78)  { return "Converging memory — dirty pages" }
        if ($Percent -lt 88)  { return "Final switchover — VM stunned (<1s)" }
        if ($Percent -lt 95)  { return "VM resumed at destination" }
        if ($Percent -lt 100) { return "Verifying VMware Tools heartbeat" }
        return "vMotion completed"
    }
}

function Update-SimulatedMigrations {
    param([array]$Migrations)

    foreach ($mig in $Migrations) {
        if ($mig.Status -eq "Completed" -or $mig.Status -eq "Failed") { continue }

        # Check if previous wave is complete
        $prevWaveOrder = $mig.WaveOrder - 1
        if ($prevWaveOrder -gt 0) {
            $prevWaveVMs = @($Migrations | Where-Object { $_.WaveOrder -eq $prevWaveOrder })
            $prevAllDone = ($prevWaveVMs | Where-Object { $_.Status -ne "Completed" }).Count -eq 0
            if (-not $prevAllDone) {
                $mig.Status = "Pending"
                $mig.Phase = "Waiting for Wave $prevWaveOrder"
                continue
            }
        }

        # Start migration if queued/pending
        if ($mig.Status -in @("Queued", "Pending")) {
            $mig.Status = "InProgress"
            $mig.StartTime = Get-Date
            $mig.Phase = "Initializing..."
        }

        # Advance progress
        if ($mig.Status -eq "InProgress") {
            $jitter = Get-Random -Minimum (-1.5) -Maximum 2.5
            $increment = $mig.TickRate + $jitter
            $mig.Percent = [math]::Min(100, [math]::Round($mig.Percent + $increment))
            $mig.DataTransferredGB = [math]::Round($mig.DataTotalGB * $mig.Percent / 100, 1)
            $mig.Phase = Get-SimulatedPhase -Percent $mig.Percent -Method $mig.Method

            # Calculate ETA
            if ($mig.Percent -gt 0 -and $mig.StartTime) {
                $elapsed = ((Get-Date) - $mig.StartTime).TotalSeconds
                $totalEstimate = $elapsed / ($mig.Percent / 100)
                $mig.ETASeconds = [math]::Max(0, [math]::Round($totalEstimate - $elapsed))
            }

            if ($mig.Percent -ge 100) {
                $mig.Status = "Completed"
                $mig.Percent = 100
                $mig.DataTransferredGB = $mig.DataTotalGB
                $mig.ETASeconds = 0
                $mig.Phase = "Migration completed successfully"
            }
        }
    }

    return $Migrations
}

# ─────────────────────────────────────────────────────────────────────────────
# Live HCX migration query
# ─────────────────────────────────────────────────────────────────────────────

function Get-LiveMigrationStatus {
    $migrations = @()
    try {
        $activeMigs = Get-HCXMigration -State "IN_PROGRESS" -ErrorAction Stop
        foreach ($mig in $activeMigs) {
            $vmInfo = $allVMs | Where-Object { $_.name -eq $mig.VMName }
            $wave = 0; $waveName = "Unknown"; $method = $mig.MigrationType
            if ($mig.VMName -match "DB")  { $wave = 1; $waveName = "Database Tier" }
            if ($mig.VMName -match "APP") { $wave = 2; $waveName = "Application Tier" }
            if ($mig.VMName -match "WEB") { $wave = 3; $waveName = "Web Tier" }

            $migrations += @{
                VMName            = $mig.VMName
                Wave              = $wave
                WaveName          = $waveName
                Method            = $method
                MigrationId       = $mig.Id
                Status            = "InProgress"
                Percent           = $mig.PercentComplete
                DataTransferredGB = if ($mig.DataTransferred) { [math]::Round($mig.DataTransferred / 1GB, 1) } else { 0 }
                DataTotalGB       = if ($vmInfo) { $vmInfo.usedSpaceGB } else { 0 }
                ETASeconds        = if ($mig.EstimatedRemainingTime) { $mig.EstimatedRemainingTime.TotalSeconds } else { 0 }
                Phase             = $mig.State
                StartTime         = $mig.StartTime
            }
        }

        $completedMigs = Get-HCXMigration -State "COMPLETED" -ErrorAction SilentlyContinue
        foreach ($mig in $completedMigs) {
            $wave = 0; $waveName = "Unknown"
            if ($mig.VMName -match "DB")  { $wave = 1; $waveName = "Database Tier" }
            if ($mig.VMName -match "APP") { $wave = 2; $waveName = "Application Tier" }
            if ($mig.VMName -match "WEB") { $wave = 3; $waveName = "Web Tier" }

            $vmInfo = $allVMs | Where-Object { $_.name -eq $mig.VMName }
            $migrations += @{
                VMName            = $mig.VMName
                Wave              = $wave
                WaveName          = $waveName
                Method            = $mig.MigrationType
                MigrationId       = $mig.Id
                Status            = "Completed"
                Percent           = 100
                DataTransferredGB = if ($vmInfo) { $vmInfo.usedSpaceGB } else { 0 }
                DataTotalGB       = if ($vmInfo) { $vmInfo.usedSpaceGB } else { 0 }
                ETASeconds        = 0
                Phase             = "Migration completed"
                StartTime         = $mig.StartTime
            }
        }
    }
    catch {
        Write-Host "  Error querying HCX: $($_.Exception.Message)" -ForegroundColor Red
    }

    if ($WaveFilter) {
        $migrations = @($migrations | Where-Object { $_.Wave -in $WaveFilter })
    }

    return $migrations
}

# ─────────────────────────────────────────────────────────────────────────────
# Main monitoring loop
# ─────────────────────────────────────────────────────────────────────────────

try {
    $monitorStart = Get-Date
    $refreshCount = 0
    $snapshotLog = [System.Collections.ArrayList]::new()

    # Initialize state
    if ($Simulate) {
        $migrations = New-SimulatedMigrationState -VMs $allVMs
    }

    while ($true) {
        $refreshCount++
        $elapsed = Format-Duration -TotalSeconds ([math]::Round(((Get-Date) - $monitorStart).TotalSeconds))

        # Get current migration state
        if ($Simulate) {
            $migrations = Update-SimulatedMigrations -Migrations $migrations
        } else {
            $migrations = Get-LiveMigrationStatus
        }

        # Render dashboard
        $mode = if ($Simulate) { "SIMULATION" } else { "LIVE" }
        Write-DashboardHeader -Mode $mode -RefreshCount $refreshCount -Elapsed $elapsed

        # Group by wave and render
        $waves = $migrations | Sort-Object Wave | Group-Object Wave
        foreach ($waveGroup in $waves) {
            $firstMig = $waveGroup.Group[0]
            Write-WaveSeparator -WaveNum $firstMig.Wave -WaveName $firstMig.WaveName -Method $firstMig.Method
            foreach ($mig in $waveGroup.Group) {
                Write-MigrationRow -Migration $mig
                if ($mig.Status -eq "InProgress") {
                    Write-PhaseDetail -Phase $mig.Phase
                }
            }
            Write-WaveFooter
        }

        # Overall summary
        $completed = @($migrations | Where-Object { $_.Status -eq "Completed" }).Count
        $inProgress = @($migrations | Where-Object { $_.Status -eq "InProgress" }).Count
        $pending = @($migrations | Where-Object { $_.Status -in @("Pending", "Queued") }).Count
        $failed = @($migrations | Where-Object { $_.Status -eq "Failed" }).Count
        $totalDataGB = ($migrations | Measure-Object -Property DataTotalGB -Sum).Sum
        $transferredDataGB = ($migrations | Measure-Object -Property DataTransferredGB -Sum).Sum

        Write-OverallSummary -TotalVMs $migrations.Count `
            -Completed $completed -InProgress $inProgress `
            -Pending $pending -Failed $failed `
            -TotalDataGB $totalDataGB -TransferredDataGB $transferredDataGB

        # Build snapshot for JSON
        $snapshot = [ordered]@{
            Timestamp      = (Get-Date).ToString("o")
            RefreshCount   = $refreshCount
            Mode           = $mode
            Elapsed        = $elapsed
            Summary        = [ordered]@{
                Total      = $migrations.Count
                Completed  = $completed
                InProgress = $inProgress
                Pending    = $pending
                Failed     = $failed
                TotalDataGB       = $totalDataGB
                TransferredDataGB = $transferredDataGB
                OverallPercent    = if ($totalDataGB -gt 0) { [math]::Round(($transferredDataGB / $totalDataGB) * 100, 1) } else { 0 }
            }
            Migrations = @($migrations | ForEach-Object {
                [ordered]@{
                    VMName            = $_.VMName
                    Wave              = $_.Wave
                    WaveName          = $_.WaveName
                    Method            = $_.Method
                    MigrationId       = $_.MigrationId
                    Status            = $_.Status
                    Percent           = $_.Percent
                    DataTransferredGB = $_.DataTransferredGB
                    DataTotalGB       = $_.DataTotalGB
                    ETASeconds        = $_.ETASeconds
                    Phase             = $_.Phase
                }
            })
        }
        [void]$snapshotLog.Add($snapshot)

        # Check exit conditions
        $allComplete = ($completed + $failed) -eq $migrations.Count -and $migrations.Count -gt 0
        if ($allComplete) {
            Write-Host "  All migrations complete. Writing final report..." -ForegroundColor Green
            break
        }

        if ($MaxRefreshes -gt 0 -and $refreshCount -ge $MaxRefreshes) {
            Write-Host "  Maximum refresh count ($MaxRefreshes) reached." -ForegroundColor Yellow
            break
        }

        Write-Host "  Press Ctrl+C to exit. Next refresh in ${RefreshIntervalSeconds}s..." -ForegroundColor DarkGray
        Start-Sleep -Seconds $RefreshIntervalSeconds
    }

    # Write final JSON report
    $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $finalReport = [ordered]@{
        MonitorMetadata = [ordered]@{
            RunDate         = (Get-Date).ToString("o")
            ScriptVersion   = "1.0.0"
            Script          = "monitor-migration.ps1"
            Mode            = $mode
            HCXServer       = $HCXServer
            TotalRefreshes  = $refreshCount
            TotalElapsed    = $elapsed
        }
        FinalStatus = $snapshot.Summary
        FinalMigrations = $snapshot.Migrations
        SnapshotHistory = $snapshotLog
    }

    $reportPath = Join-Path $OutputPath "monitor-migration-report-$timestamp.json"
    $finalReport | ConvertTo-Json -Depth 15 | Set-Content -Path $reportPath -Encoding UTF8
    Write-Host ""
    Write-Host "  Monitor report saved: $reportPath" -ForegroundColor Cyan

    # Write latest status snapshot
    $statusPath = Join-Path $OutputPath "migration-status-latest.json"
    $snapshot | ConvertTo-Json -Depth 10 | Set-Content -Path $statusPath -Encoding UTF8
    Write-Host "  Latest status: $statusPath" -ForegroundColor Cyan
    Write-Host ""
}
catch {
    Write-Host "FATAL: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "Stack: $($_.ScriptStackTrace)" -ForegroundColor Red
    exit 1
}
