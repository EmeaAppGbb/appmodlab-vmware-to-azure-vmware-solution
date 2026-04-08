<#
.SYNOPSIS
    Automates HCX migration waves for the Harbor Retail VMware-to-AVS migration.

.DESCRIPTION
    Orchestrates a three-wave HCX migration strategy with full pre-migration
    validation, simulated migration execution, and post-migration checks:

      Wave 1 — Web Tier  : HARBOR-WEB01, HARBOR-WEB02
      Wave 2 — App Tier  : HARBOR-APP01, HARBOR-APP02
      Wave 3 — DB Tier   : HARBOR-DB01

    For each wave the script performs:
      1. Pre-migration checks (VMware Tools, snapshots, network, DNS, services)
      2. Migration execution via HCX (simulated unless -Live is specified)
      3. Post-migration validation (power state, IP reachability, services, DNS)
      4. Progress reporting with estimated times

    The script generates detailed JSON reports covering every step and VM.
    In simulation mode all HCX API calls are replaced with realistic delays
    and deterministic success responses.

.PARAMETER VCenterServer
    Source vCenter Server FQDN or IP.

.PARAMETER HCXServer
    HCX Manager FQDN or IP for migration orchestration.

.PARAMETER AVSVCenterServer
    Destination AVS vCenter FQDN or IP for post-migration validation.

.PARAMETER Credential
    PSCredential for vCenter / HCX authentication.

.PARAMETER InventoryPath
    Path to vcenter-inventory-export.json from export-inventory.ps1.
    Defaults to .\output\vcenter-inventory-export.json.

.PARAMETER OutputPath
    Directory for migration reports. Defaults to .\output.

.PARAMETER Simulate
    Run the entire migration workflow using simulated HCX operations.

.PARAMETER WaveFilter
    Restrict execution to specific wave numbers. E.g. -WaveFilter 1,2
    runs only Waves 1 and 2.

.PARAMETER MigrationMethod
    HCX migration method to use. Default: vMotion.
    Options: vMotion, BulkMigration, ColdMigration.

.PARAMETER MaintenanceWindow
    Descriptive label for the maintenance window. Written into the report.

.PARAMETER DryRun
    When specified with -Live, performs all pre-checks but skips actual
    migration execution. Useful for validating readiness.

.PARAMETER MaxParallelMigrations
    Maximum number of VMs to migrate in parallel within a wave. Default: 2.

.EXAMPLE
    .\migration-runbook.ps1 -VCenterServer vcenter.harbor.local `
        -HCXServer hcx.harbor.local -Simulate
    Runs the full three-wave migration in simulation mode.

.EXAMPLE
    .\migration-runbook.ps1 -VCenterServer vcenter.harbor.local `
        -HCXServer hcx.harbor.local -Simulate -WaveFilter 1
    Simulates only Wave 1 (Web Tier).

.EXAMPLE
    .\migration-runbook.ps1 -VCenterServer vcenter.harbor.local `
        -HCXServer hcx.harbor.local -AVSVCenterServer avs-vcenter.azure.local `
        -Credential (Get-Credential) -Live -DryRun
    Connects live and runs pre-checks without migrating.

.NOTES
    Author  : Harbor Retail Platform Engineering
    Requires: PowerShell 5.1+, VMware PowerCLI 13.0+ and HCX PowerCLI (live mode)
    Version : 1.0.0
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, HelpMessage = "Source vCenter FQDN or IP")]
    [string]$VCenterServer,

    [Parameter(Mandatory = $true, HelpMessage = "HCX Manager FQDN or IP")]
    [string]$HCXServer,

    [Parameter(Mandatory = $false, HelpMessage = "Destination AVS vCenter")]
    [string]$AVSVCenterServer = "avs-vcenter.azure.local",

    [Parameter(Mandatory = $false, HelpMessage = "Authentication credential")]
    [PSCredential]$Credential,

    [Parameter(Mandatory = $false, HelpMessage = "Path to inventory export JSON")]
    [string]$InventoryPath,

    [Parameter(Mandatory = $false, HelpMessage = "Output directory")]
    [string]$OutputPath = ".\output",

    [Parameter(Mandatory = $false, HelpMessage = "Simulate HCX operations")]
    [switch]$Simulate,

    [Parameter(Mandatory = $false, HelpMessage = "Waves to execute (1, 2, 3)")]
    [ValidateRange(1, 3)]
    [int[]]$WaveFilter,

    [Parameter(Mandatory = $false, HelpMessage = "HCX migration method")]
    [ValidateSet("vMotion", "BulkMigration", "ColdMigration")]
    [string]$MigrationMethod = "vMotion",

    [Parameter(Mandatory = $false, HelpMessage = "Maintenance window label")]
    [string]$MaintenanceWindow = "Scheduled Maintenance",

    [Parameter(Mandatory = $false, HelpMessage = "Pre-check only, skip migration")]
    [switch]$DryRun,

    [Parameter(Mandatory = $false, HelpMessage = "Max parallel migrations per wave")]
    [ValidateRange(1, 10)]
    [int]$MaxParallelMigrations = 2
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$script:StartTime = Get-Date
$script:MigrationLog = [System.Collections.ArrayList]::new()

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet("INFO", "WARN", "ERROR", "SUCCESS")]
        [string]$Level = "INFO"
    )
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $colors = @{ INFO = "Cyan"; WARN = "Yellow"; ERROR = "Red"; SUCCESS = "Green" }
    Write-Host "[$ts] [$Level] $Message" -ForegroundColor $colors[$Level]
    [void]$script:MigrationLog.Add([ordered]@{
        Timestamp = $ts
        Level     = $Level
        Message   = $Message
    })
}

function Write-Banner {
    param([string]$Text)
    $border = "=" * 60
    Write-Host ""
    Write-Host $border -ForegroundColor Magenta
    Write-Host "  $Text" -ForegroundColor Magenta
    Write-Host $border -ForegroundColor Magenta
    Write-Host ""
}

function Write-WaveProgress {
    param(
        [int]$WaveNum,
        [string]$Status,
        [int]$PercentComplete
    )
    Write-Progress -Activity "Migration Runbook" `
        -Status "Wave $WaveNum - $Status" `
        -PercentComplete $PercentComplete
}

# ---------------------------------------------------------------------------
# Wave definitions — maps the Harbor Retail three-tier architecture
# ---------------------------------------------------------------------------

function Get-MigrationWaves {
    <#
    .SYNOPSIS
        Returns the ordered migration wave plan.
        Wave order follows dependency chain: Web -> App -> DB (reverse dependency
        so least critical migrates first).
    #>
    param([array]$AllVMs)

    $waves = @(
        [ordered]@{
            WaveNumber  = 1
            Name        = "Web Tier"
            Description = "Front-end IIS web servers — lowest risk, validates HCX connectivity"
            Tier        = "Web"
            VMs         = @($AllVMs | Where-Object { $_.ResourcePool -eq "Web-Pool" -or $_.Name -match "WEB" })
            MigrationMethod     = $MigrationMethod
            MaxParallel         = $MaxParallelMigrations
            EstimatedMinutes    = 30
            PreMigrationChecks  = @("VMwareTools", "Snapshots", "NetworkConnectivity", "ServiceHealth", "DNS")
            PostMigrationChecks = @("PowerState", "IPReachability", "ServiceHealth", "DNS", "WebEndpoint")
            RollbackPlan        = "Re-register VMs on source vCenter and restore DNS A-records."
        },
        [ordered]@{
            WaveNumber  = 2
            Name        = "App Tier"
            Description = "API application servers — moderate risk, validate API endpoints post-migration"
            Tier        = "App"
            VMs         = @($AllVMs | Where-Object { $_.ResourcePool -eq "App-Pool" -or $_.Name -match "APP" })
            MigrationMethod     = $MigrationMethod
            MaxParallel         = $MaxParallelMigrations
            EstimatedMinutes    = 45
            PreMigrationChecks  = @("VMwareTools", "Snapshots", "NetworkConnectivity", "ServiceHealth", "DNS", "APIHealth")
            PostMigrationChecks = @("PowerState", "IPReachability", "ServiceHealth", "DNS", "APIHealth", "DatabaseConnectivity")
            RollbackPlan        = "Reverse-vMotion VMs to source. Verify API endpoints resolve to source IPs."
        },
        [ordered]@{
            WaveNumber  = 3
            Name        = "DB Tier"
            Description = "SQL Server database — highest risk, requires extended maintenance window"
            Tier        = "DB"
            VMs         = @($AllVMs | Where-Object { $_.ResourcePool -eq "DB-Pool" -or $_.Name -match "DB" })
            MigrationMethod     = $MigrationMethod
            MaxParallel         = 1
            EstimatedMinutes    = 90
            PreMigrationChecks  = @("VMwareTools", "Snapshots", "NetworkConnectivity", "ServiceHealth", "DNS", "SQLHealth", "BackupStatus")
            PostMigrationChecks = @("PowerState", "IPReachability", "ServiceHealth", "DNS", "SQLHealth", "DatabaseIntegrity", "BackupValidation")
            RollbackPlan        = "Restore from last full backup on source SQL Server. Verify transaction log chain."
        }
    )

    return $waves
}

# ---------------------------------------------------------------------------
# Pre-migration check functions
# ---------------------------------------------------------------------------

function Invoke-PreMigrationCheck {
    <#
    .SYNOPSIS
        Runs all pre-migration checks for a single VM.
        Returns a result object with pass/fail per check.
    #>
    param(
        [hashtable]$VM,
        [string[]]$Checks
    )

    Write-Log "  Pre-migration checks for $($VM.Name)..."
    $results = [System.Collections.ArrayList]::new()

    foreach ($check in $Checks) {
        $checkResult = [ordered]@{
            Check     = $check
            Status    = "Pass"
            Message   = ""
            Timestamp = (Get-Date).ToString("o")
        }

        switch ($check) {
            "VMwareTools" {
                if ($VM.VMToolsStatus -eq "toolsOk") {
                    $checkResult.Message = "VMware Tools $($VM.VMToolsVersion) running."
                }
                elseif (-not $VM.VMToolsVersion) {
                    $checkResult.Status  = "Fail"
                    $checkResult.Message = "VMware Tools not installed."
                }
                else {
                    $checkResult.Status  = "Warn"
                    $checkResult.Message = "VMware Tools status: $($VM.VMToolsStatus)."
                }
            }

            "Snapshots" {
                $snapCount = if ($VM.Snapshots) { $VM.Snapshots.Count } else { 0 }
                if ($snapCount -eq 0) {
                    $checkResult.Message = "No snapshots present."
                }
                else {
                    $checkResult.Status  = "Fail"
                    $checkResult.Message = "$snapCount snapshot(s) found — must be removed."
                }
            }

            "NetworkConnectivity" {
                $ip = $null
                if ($VM.NetworkAdapters -and $VM.NetworkAdapters.Count -gt 0) {
                    $ip = $VM.NetworkAdapters[0].IPAddress
                }
                if ($Simulate) {
                    $checkResult.Message = "Simulated ping to $ip — success."
                }
                else {
                    if ($ip -and (Test-Connection -ComputerName $ip -Count 2 -Quiet -ErrorAction SilentlyContinue)) {
                        $checkResult.Message = "Ping to $ip successful."
                    }
                    else {
                        $checkResult.Status  = "Warn"
                        $checkResult.Message = "Cannot reach $ip — verify network path."
                    }
                }
            }

            "ServiceHealth" {
                if ($Simulate) {
                    $checkResult.Message = "Simulated service health check — all services running."
                }
                else {
                    $checkResult.Message = "Service health check requires WinRM/agent — skipped in non-simulated mode without agent."
                    $checkResult.Status = "Warn"
                }
            }

            "DNS" {
                $ip = if ($VM.NetworkAdapters) { $VM.NetworkAdapters[0].IPAddress } else { $null }
                $hostname = $VM.Name.ToLower() -replace "harbor-", ""
                if ($Simulate) {
                    $checkResult.Message = "DNS record '$hostname.harbor.local' resolves to $ip."
                }
                else {
                    try {
                        $resolved = Resolve-DnsName -Name "$hostname.harbor.local" -ErrorAction Stop
                        $checkResult.Message = "DNS resolves to $($resolved.IPAddress)."
                    }
                    catch {
                        $checkResult.Status  = "Warn"
                        $checkResult.Message = "DNS resolution failed for $hostname.harbor.local."
                    }
                }
            }

            "APIHealth" {
                if ($Simulate) {
                    $port = if ($VM.FirewallRules) {
                        ($VM.FirewallRules | Where-Object { $_.Name -match "API HTTPS" }).Port
                    } else { 8443 }
                    $checkResult.Message = "Simulated API health check on port $port — HTTP 200 OK."
                }
                else {
                    $checkResult.Message = "API health check requires network access — manual verification recommended."
                    $checkResult.Status = "Warn"
                }
            }

            "SQLHealth" {
                if ($Simulate) {
                    $checkResult.Message = "Simulated SQL Server health check — instance online, all databases accessible."
                }
                else {
                    $checkResult.Message = "SQL health check requires SQL connectivity — manual verification recommended."
                    $checkResult.Status = "Warn"
                }
            }

            "BackupStatus" {
                if ($Simulate) {
                    $checkResult.Message = "Last full backup completed at $((Get-Date).AddHours(-6).ToString('yyyy-MM-dd HH:mm')) — within RPO."
                }
                else {
                    $checkResult.Message = "Backup status requires SQL agent access — verify manually."
                    $checkResult.Status = "Warn"
                }
            }

            default {
                $checkResult.Message = "Check '$check' not implemented — skipped."
                $checkResult.Status  = "Warn"
            }
        }

        Write-Log "    [$($checkResult.Status)] $check : $($checkResult.Message)" -Level $(
            switch ($checkResult.Status) { "Pass" { "SUCCESS" }; "Warn" { "WARN" }; "Fail" { "ERROR" } }
        )
        [void]$results.Add($checkResult)
    }

    $overallStatus = "Pass"
    if ($results | Where-Object { $_.Status -eq "Fail" }) { $overallStatus = "Fail" }
    elseif ($results | Where-Object { $_.Status -eq "Warn" }) { $overallStatus = "Warn" }

    return [ordered]@{
        VMName        = $VM.Name
        OverallStatus = $overallStatus
        Checks        = $results
        Timestamp     = (Get-Date).ToString("o")
    }
}

# ---------------------------------------------------------------------------
# Simulated HCX migration execution
# ---------------------------------------------------------------------------

function Invoke-SimulatedHCXMigration {
    <#
    .SYNOPSIS
        Simulates an HCX vMotion/Bulk/Cold migration for a single VM.
        Produces realistic progress updates and timing.
    #>
    param(
        [hashtable]$VM,
        [string]$Method,
        [string]$DestinationVCenter
    )

    $migrationId = "HCX-MIG-" + [guid]::NewGuid().ToString().Substring(0, 8).ToUpper()
    $storageGB = ($VM.Disks | ForEach-Object { $_.CapacityGB } | Measure-Object -Sum).Sum

    Write-Log "    Migration ID    : $migrationId"
    Write-Log "    Method          : $Method"
    Write-Log "    VM              : $($VM.Name) ($($VM.NumCpu) vCPU, $($VM.MemoryGB) GB RAM, $storageGB GB disk)"
    Write-Log "    Destination     : $DestinationVCenter"

    $phases = @(
        @{ Name = "Initializing HCX migration task";        Pct = 5;  SleepMs = 500  }
        @{ Name = "Validating source VM configuration";     Pct = 10; SleepMs = 400  }
        @{ Name = "Creating destination placeholder VM";    Pct = 15; SleepMs = 300  }
        @{ Name = "Configuring HCX network extension";      Pct = 20; SleepMs = 400  }
        @{ Name = "Starting initial disk replication";      Pct = 30; SleepMs = 800  }
        @{ Name = "Replicating disk 1 ($($VM.Disks[0].CapacityGB) GB)"; Pct = 50; SleepMs = 1000 }
    )

    if ($VM.Disks.Count -gt 1) {
        $phases += @{ Name = "Replicating disk 2 ($($VM.Disks[1].CapacityGB) GB)"; Pct = 60; SleepMs = 800 }
    }

    $phases += @(
        @{ Name = "Delta sync — transferring changed blocks"; Pct = 70; SleepMs = 600 }
        @{ Name = "Quiescing source VM";                      Pct = 75; SleepMs = 400 }
        @{ Name = "Final delta replication";                  Pct = 80; SleepMs = 500 }
        @{ Name = "Switching over to destination";            Pct = 85; SleepMs = 400 }
        @{ Name = "Powering on VM at destination";            Pct = 90; SleepMs = 600 }
        @{ Name = "Verifying VMware Tools heartbeat";         Pct = 95; SleepMs = 500 }
        @{ Name = "Migration completed successfully";         Pct = 100; SleepMs = 200 }
    )

    $phaseResults = [System.Collections.ArrayList]::new()
    $migStart = Get-Date

    foreach ($phase in $phases) {
        Write-Progress -Activity "Migrating $($VM.Name)" `
            -Status $phase.Name -PercentComplete $phase.Pct
        Start-Sleep -Milliseconds $phase.SleepMs

        [void]$phaseResults.Add([ordered]@{
            Phase      = $phase.Name
            Percent    = $phase.Pct
            Timestamp  = (Get-Date).ToString("o")
        })
        Write-Log "    [$($phase.Pct)%] $($phase.Name)"
    }

    $migDuration = (Get-Date) - $migStart

    Write-Progress -Activity "Migrating $($VM.Name)" -Completed

    return [ordered]@{
        MigrationId       = $migrationId
        VMName            = $VM.Name
        Method            = $Method
        SourceVCenter     = $VCenterServer
        DestinationVCenter = $DestinationVCenter
        Status            = "Completed"
        StartTime         = $migStart.ToString("o")
        EndTime           = (Get-Date).ToString("o")
        DurationSeconds   = [math]::Round($migDuration.TotalSeconds, 1)
        StorageMigratedGB = $storageGB
        Phases            = $phaseResults
    }
}

# ---------------------------------------------------------------------------
# Post-migration validation
# ---------------------------------------------------------------------------

function Invoke-PostMigrationValidation {
    <#
    .SYNOPSIS
        Runs post-migration validation checks against a migrated VM.
    #>
    param(
        [hashtable]$VM,
        [string[]]$Checks
    )

    Write-Log "  Post-migration validation for $($VM.Name)..."
    $results = [System.Collections.ArrayList]::new()

    foreach ($check in $Checks) {
        $checkResult = [ordered]@{
            Check     = $check
            Status    = "Pass"
            Message   = ""
            Timestamp = (Get-Date).ToString("o")
        }

        switch ($check) {
            "PowerState" {
                if ($Simulate) {
                    $checkResult.Message = "VM is powered on at destination."
                }
                else {
                    $checkResult.Message = "Verify VM power state in AVS vCenter."
                    $checkResult.Status = "Warn"
                }
            }

            "IPReachability" {
                $ip = if ($VM.NetworkAdapters) { $VM.NetworkAdapters[0].IPAddress } else { "unknown" }
                if ($Simulate) {
                    $checkResult.Message = "Ping to $ip via AVS NSX-T segment — success (2ms avg)."
                }
                else {
                    if ($ip -ne "unknown" -and (Test-Connection -ComputerName $ip -Count 2 -Quiet -ErrorAction SilentlyContinue)) {
                        $checkResult.Message = "Ping to $ip successful."
                    }
                    else {
                        $checkResult.Status  = "Fail"
                        $checkResult.Message = "Cannot reach $ip post-migration."
                    }
                }
            }

            "ServiceHealth" {
                if ($Simulate) {
                    if ($VM.Name -match "WEB") {
                        $checkResult.Message = "IIS service (W3SVC) running. Port 443 listening."
                    }
                    elseif ($VM.Name -match "APP") {
                        $checkResult.Message = "Harbor Retail API service running. Port 8443 listening."
                    }
                    elseif ($VM.Name -match "DB") {
                        $checkResult.Message = "SQL Server service (MSSQLSERVER) running. Port 1433 listening."
                    }
                    else {
                        $checkResult.Message = "Core services verified running."
                    }
                }
                else {
                    $checkResult.Message = "Service validation requires remote access — verify manually."
                    $checkResult.Status = "Warn"
                }
            }

            "DNS" {
                $ip = if ($VM.NetworkAdapters) { $VM.NetworkAdapters[0].IPAddress } else { "unknown" }
                $hostname = $VM.Name.ToLower() -replace "harbor-", ""
                if ($Simulate) {
                    $checkResult.Message = "DNS '$hostname.harbor.local' resolves to $ip — matches expected."
                }
                else {
                    $checkResult.Message = "DNS validation recommended — verify A-record consistency."
                    $checkResult.Status = "Warn"
                }
            }

            "WebEndpoint" {
                if ($Simulate) {
                    $checkResult.Message = "HTTPS GET https://www.harbor-retail.com/ returned HTTP 200 OK (response: 145ms)."
                }
                else {
                    try {
                        $response = Invoke-WebRequest -Uri "https://www.harbor-retail.com/" -UseBasicParsing -TimeoutSec 10
                        $checkResult.Message = "Web endpoint returned HTTP $($response.StatusCode)."
                    }
                    catch {
                        $checkResult.Status  = "Fail"
                        $checkResult.Message = "Web endpoint unreachable: $_"
                    }
                }
            }

            "APIHealth" {
                if ($Simulate) {
                    $ip = if ($VM.NetworkAdapters) { $VM.NetworkAdapters[0].IPAddress } else { "10.10.20.11" }
                    $checkResult.Message = "API health endpoint https://$($ip):8443/health returned HTTP 200 OK."
                }
                else {
                    $checkResult.Message = "API health check requires network access — verify manually."
                    $checkResult.Status = "Warn"
                }
            }

            "DatabaseConnectivity" {
                if ($Simulate) {
                    $checkResult.Message = "TCP connection to 10.10.30.11:1433 (HARBOR-DB01) from app tier — success."
                }
                else {
                    $checkResult.Message = "Database connectivity check — verify SQL port 1433 reachable from app tier."
                    $checkResult.Status = "Warn"
                }
            }

            "SQLHealth" {
                if ($Simulate) {
                    $checkResult.Message = "SQL Server instance online. Databases: HarborRetail (ONLINE), HarborRetail_Archive (ONLINE), HarborRetail_Staging (ONLINE)."
                }
                else {
                    $checkResult.Message = "SQL health requires SQL connectivity — verify manually."
                    $checkResult.Status = "Warn"
                }
            }

            "DatabaseIntegrity" {
                if ($Simulate) {
                    $checkResult.Message = "DBCC CHECKDB completed with no errors for all databases."
                }
                else {
                    $checkResult.Message = "Run DBCC CHECKDB on all databases post-migration."
                    $checkResult.Status = "Warn"
                }
            }

            "BackupValidation" {
                if ($Simulate) {
                    $checkResult.Message = "Post-migration full backup initiated and completed successfully."
                }
                else {
                    $checkResult.Message = "Take a full backup immediately after migration — verify backup chain."
                    $checkResult.Status = "Warn"
                }
            }

            default {
                $checkResult.Message = "Check '$check' not implemented."
                $checkResult.Status  = "Warn"
            }
        }

        $lvl = switch ($checkResult.Status) { "Pass" { "SUCCESS" }; "Warn" { "WARN" }; "Fail" { "ERROR" } }
        Write-Log "    [$($checkResult.Status)] $check : $($checkResult.Message)" -Level $lvl
        [void]$results.Add($checkResult)
    }

    $overallStatus = "Pass"
    if ($results | Where-Object { $_.Status -eq "Fail" }) { $overallStatus = "Fail" }
    elseif ($results | Where-Object { $_.Status -eq "Warn" }) { $overallStatus = "Warn" }

    return [ordered]@{
        VMName        = $VM.Name
        OverallStatus = $overallStatus
        Checks        = $results
        Timestamp     = (Get-Date).ToString("o")
    }
}

# ---------------------------------------------------------------------------
# Wave execution orchestrator
# ---------------------------------------------------------------------------

function Invoke-MigrationWave {
    <#
    .SYNOPSIS
        Executes a single migration wave: pre-checks -> migrate -> post-validate.
    #>
    param([hashtable]$Wave)

    $waveResult = [ordered]@{
        WaveNumber      = $Wave.WaveNumber
        WaveName        = $Wave.Name
        Description     = $Wave.Description
        Tier            = $Wave.Tier
        MigrationMethod = $Wave.MigrationMethod
        RollbackPlan    = $Wave.RollbackPlan
        Status          = "InProgress"
        StartTime       = (Get-Date).ToString("o")
        EndTime         = $null
        DurationSeconds = $null
        VMs             = [System.Collections.ArrayList]::new()
    }

    $vmCount = $Wave.VMs.Count
    Write-Banner "Wave $($Wave.WaveNumber): $($Wave.Name) ($vmCount VMs)"
    Write-Log "Description     : $($Wave.Description)"
    Write-Log "Migration method: $($Wave.MigrationMethod)"
    Write-Log "Max parallel    : $($Wave.MaxParallel)"
    Write-Log "Est. duration   : $($Wave.EstimatedMinutes) minutes"
    Write-Log ""

    # --- Phase 1: Pre-migration checks ---
    Write-Banner "Phase 1: Pre-Migration Checks"
    $allPreChecksPassed = $true

    foreach ($vm in $Wave.VMs) {
        $preResult = Invoke-PreMigrationCheck -VM $vm -Checks $Wave.PreMigrationChecks
        $vmEntry = [ordered]@{
            VMName              = $vm.Name
            PreMigrationChecks  = $preResult
            MigrationResult     = $null
            PostMigrationChecks = $null
        }

        if ($preResult.OverallStatus -eq "Fail") {
            $allPreChecksPassed = $false
            Write-Log "  BLOCKED: $($vm.Name) failed pre-migration checks." -Level ERROR
        }

        [void]$waveResult.VMs.Add($vmEntry)
    }

    if (-not $allPreChecksPassed) {
        Write-Log "One or more VMs failed pre-checks. Wave $($Wave.WaveNumber) is BLOCKED." -Level ERROR
        $waveResult.Status  = "Blocked"
        $waveResult.EndTime = (Get-Date).ToString("o")
        $waveResult.DurationSeconds = [math]::Round(((Get-Date) - [datetime]$waveResult.StartTime).TotalSeconds, 1)
        return $waveResult
    }

    Write-Log "All pre-migration checks passed." -Level SUCCESS
    Write-Log ""

    # --- Phase 2: Migration execution ---
    if ($DryRun) {
        Write-Banner "Phase 2: Migration Execution (DRY RUN — skipped)"
        Write-Log "DryRun mode — migration execution skipped." -Level WARN

        foreach ($vmEntry in $waveResult.VMs) {
            $vmEntry.MigrationResult = [ordered]@{
                Status  = "Skipped"
                Message = "DryRun mode — no migration performed."
            }
        }
    }
    else {
        Write-Banner "Phase 2: Migration Execution"

        foreach ($vmEntry in $waveResult.VMs) {
            $vm = $Wave.VMs | Where-Object { $_.Name -eq $vmEntry.VMName }
            Write-Log "Migrating $($vm.Name)..." -Level INFO

            if ($Simulate) {
                $migResult = Invoke-SimulatedHCXMigration -VM $vm -Method $Wave.MigrationMethod -DestinationVCenter $AVSVCenterServer
            }
            else {
                # Live HCX migration — requires HCX PowerCLI module
                Write-Log "  Initiating live HCX $($Wave.MigrationMethod) for $($vm.Name)..." -Level INFO
                try {
                    $hcxVM = Get-HCXVM -Name $vm.Name -ErrorAction Stop
                    $targetSite = Get-HCXSite -Destination -ErrorAction Stop
                    $targetDatastore = Get-HCXDatastore -Site $targetSite -Name "vsanDatastore" -ErrorAction Stop
                    $targetFolder = Get-HCXContainer -Site $targetSite -Type Folder -Name $Wave.Tier -ErrorAction Stop
                    $targetRP = Get-HCXContainer -Site $targetSite -Type ResourcePool -Name "$($Wave.Tier)-Pool" -ErrorAction Stop

                    $networkMap = @()
                    foreach ($nic in $vm.NetworkAdapters) {
                        $sourceNet = Get-HCXNetwork -Name $nic.NetworkName -Site (Get-HCXSite -Source) -ErrorAction Stop
                        $destNet   = Get-HCXNetwork -Name $nic.NetworkName -Site $targetSite -ErrorAction Stop
                        $networkMap += New-HCXNetworkMapping -SourceNetwork $sourceNet -DestinationNetwork $destNet
                    }

                    $migration = New-HCXMigration -VM $hcxVM `
                        -MigrationType $Wave.MigrationMethod `
                        -TargetSite $targetSite `
                        -TargetDatastore $targetDatastore `
                        -TargetFolder $targetFolder `
                        -TargetResourcePool $targetRP `
                        -NetworkMapping $networkMap `
                        -ErrorAction Stop

                    Start-HCXMigration -Migration $migration -Confirm:$false -ErrorAction Stop

                    # Poll until complete
                    $timeout = New-TimeSpan -Minutes 120
                    $sw = [Diagnostics.Stopwatch]::StartNew()
                    do {
                        Start-Sleep -Seconds 30
                        $status = Get-HCXMigration -MigrationId $migration.Id
                        Write-Log "    [$($status.PercentComplete)%] $($status.State)" -Level INFO
                    } while ($status.State -notin @("COMPLETED", "FAILED", "CANCELLED") -and $sw.Elapsed -lt $timeout)

                    $migResult = [ordered]@{
                        MigrationId = $migration.Id
                        VMName      = $vm.Name
                        Method      = $Wave.MigrationMethod
                        Status      = $status.State
                        StartTime   = $migration.StartTime.ToString("o")
                        EndTime     = (Get-Date).ToString("o")
                    }
                }
                catch {
                    $migResult = [ordered]@{
                        VMName  = $vm.Name
                        Status  = "Failed"
                        Error   = $_.Exception.Message
                    }
                    Write-Log "  Migration FAILED for $($vm.Name): $($_.Exception.Message)" -Level ERROR
                }
            }

            $vmEntry.MigrationResult = $migResult
            if ($migResult.Status -eq "Completed") {
                Write-Log "  $($vm.Name) migrated successfully ($($migResult.DurationSeconds)s)" -Level SUCCESS
            }
            elseif ($migResult.Status -eq "Failed") {
                Write-Log "  $($vm.Name) migration FAILED" -Level ERROR
            }
        }
    }

    Write-Log ""

    # --- Phase 3: Post-migration validation ---
    if (-not $DryRun) {
        Write-Banner "Phase 3: Post-Migration Validation"

        foreach ($vmEntry in $waveResult.VMs) {
            $vm = $Wave.VMs | Where-Object { $_.Name -eq $vmEntry.VMName }
            if ($vmEntry.MigrationResult.Status -eq "Completed" -or $Simulate) {
                $postResult = Invoke-PostMigrationValidation -VM $vm -Checks $Wave.PostMigrationChecks
                $vmEntry.PostMigrationChecks = $postResult
            }
            else {
                $vmEntry.PostMigrationChecks = [ordered]@{
                    VMName        = $vm.Name
                    OverallStatus = "Skipped"
                    Message       = "Migration did not complete — post-checks skipped."
                }
                Write-Log "  Skipping post-checks for $($vm.Name) — migration incomplete." -Level WARN
            }
        }
    }

    # Determine wave status
    $failedVMs = @($waveResult.VMs | Where-Object {
        $_['MigrationResult'] -and $_['MigrationResult']['Status'] -eq "Failed" -or
        ($_['PostMigrationChecks'] -and $_['PostMigrationChecks']['OverallStatus'] -eq "Fail")
    })

    if ($DryRun) {
        $waveResult.Status = "DryRun"
    }
    elseif ($failedVMs.Count -gt 0) {
        $waveResult.Status = "CompletedWithErrors"
    }
    else {
        $waveResult.Status = "Completed"
    }

    $waveResult.EndTime = (Get-Date).ToString("o")
    $waveResult.DurationSeconds = [math]::Round(((Get-Date) - [datetime]$waveResult.StartTime).TotalSeconds, 1)

    Write-Log ""
    $statusColor = switch ($waveResult.Status) {
        "Completed"           { "SUCCESS" }
        "CompletedWithErrors" { "WARN" }
        "Blocked"             { "ERROR" }
        "DryRun"              { "INFO" }
    }
    Write-Log "Wave $($Wave.WaveNumber) '$($Wave.Name)' finished — Status: $($waveResult.Status) ($($waveResult.DurationSeconds)s)" -Level $statusColor

    return $waveResult
}

# ---------------------------------------------------------------------------
# Main execution
# ---------------------------------------------------------------------------

try {
    Write-Banner "Harbor Retail HCX Migration Runbook"
    Write-Log "Source vCenter   : $VCenterServer"
    Write-Log "HCX Manager      : $HCXServer"
    Write-Log "AVS vCenter      : $AVSVCenterServer"
    Write-Log "Migration method  : $MigrationMethod"
    Write-Log "Mode              : $(if ($Simulate) { 'SIMULATION' } else { 'LIVE' })$(if ($DryRun) { ' (DRY RUN)' })"
    Write-Log "Maintenance window: $MaintenanceWindow"
    Write-Log "Wave filter       : $(if ($WaveFilter) { $WaveFilter -join ', ' } else { 'All waves' })"
    Write-Log ""

    # Ensure output directory
    if (-not (Test-Path $OutputPath)) {
        New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
    }

    # Load inventory
    Write-Log "Loading VM inventory..."
    if ($Simulate) {
        $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
        $exportScript = Join-Path $scriptDir "export-inventory.ps1"

        if (Test-Path $exportScript) {
            $inventoryFile = Join-Path $OutputPath "vcenter-inventory-export.json"
            if (-not (Test-Path $inventoryFile)) {
                Write-Log "Running export-inventory.ps1 to generate inventory..."
                & $exportScript -VCenterServer $VCenterServer -Simulate -OutputPath $OutputPath
            }
            $inventory = Get-Content $inventoryFile -Raw | ConvertFrom-Json -AsHashtable
        }
        else {
            throw "export-inventory.ps1 not found at $exportScript. Run it first."
        }
    }
    else {
        $invPath = if ($InventoryPath) { $InventoryPath } else { Join-Path $OutputPath "vcenter-inventory-export.json" }
        if (-not (Test-Path $invPath)) {
            throw "Inventory not found at '$invPath'. Run export-inventory.ps1 first."
        }
        $inventory = Get-Content $invPath -Raw | ConvertFrom-Json -AsHashtable
    }

    $allVMs = $inventory.VirtualMachines
    Write-Log "Loaded $($allVMs.Count) VMs" -Level SUCCESS

    # Build waves
    $waves = Get-MigrationWaves -AllVMs $allVMs

    if ($WaveFilter) {
        $waves = $waves | Where-Object { $_.WaveNumber -in $WaveFilter }
        Write-Log "Filtered to wave(s): $($WaveFilter -join ', ')"
    }

    Write-Log ""
    Write-Log "--- Migration Plan ---"
    foreach ($wave in $waves) {
        $vmNames = ($wave.VMs | ForEach-Object { $_.Name }) -join ", "
        Write-Log "  Wave $($wave.WaveNumber) [$($wave.Name)]: $vmNames (est. $($wave.EstimatedMinutes) min)"
    }
    Write-Log ""

    # Execute waves sequentially
    $waveResults = [System.Collections.ArrayList]::new()
    $waveIndex = 0

    foreach ($wave in $waves) {
        $waveIndex++
        $overallPct = [math]::Round(($waveIndex / $waves.Count) * 100)
        Write-WaveProgress -WaveNum $wave.WaveNumber -Status "Starting..." -PercentComplete $overallPct

        $result = Invoke-MigrationWave -Wave $wave
        [void]$waveResults.Add($result)

        # Stop if a wave is blocked (critical failure)
        if ($result.Status -eq "Blocked") {
            Write-Log "HALTING: Wave $($wave.WaveNumber) is blocked. Remaining waves will not execute." -Level ERROR
            break
        }
    }

    Write-Progress -Activity "Migration Runbook" -Completed

    # Build summary
    $totalDuration = (Get-Date) - $script:StartTime
    $migrated   = 0
    $failed     = 0
    $skipped    = 0
    foreach ($wr in $waveResults) {
        foreach ($vmr in $wr.VMs) {
            if ($vmr.MigrationResult) {
                switch ($vmr.MigrationResult.Status) {
                    "Completed" { $migrated++ }
                    "Failed"    { $failed++ }
                    "Skipped"   { $skipped++ }
                }
            }
        }
    }

    $overallStatus = if ($failed -gt 0) { "CompletedWithErrors" }
                     elseif ($DryRun) { "DryRun" }
                     else { "Completed" }

    # Assemble final report
    $report = [ordered]@{
        RunbookMetadata = [ordered]@{
            RunDate            = (Get-Date).ToString("o")
            ScriptVersion      = "1.0.0"
            Mode               = if ($Simulate) { "Simulation" } else { "Live" }
            DryRun             = [bool]$DryRun
            SourceVCenter      = $VCenterServer
            HCXManager         = $HCXServer
            DestinationVCenter = $AVSVCenterServer
            MigrationMethod    = $MigrationMethod
            MaintenanceWindow  = $MaintenanceWindow
            TotalDuration      = "$([math]::Round($totalDuration.TotalSeconds, 1))s"
        }
        OverallStatus = [ordered]@{
            Status       = $overallStatus
            TotalVMs     = $allVMs.Count
            Migrated     = $migrated
            Failed       = $failed
            Skipped      = $skipped
            WavesPlanned = $waves.Count
            WavesExecuted = $waveResults.Count
        }
        WaveResults   = $waveResults
        MigrationLog  = $script:MigrationLog
    }

    # Write reports
    $reportPath = Join-Path $OutputPath "migration-runbook-report.json"
    $report | ConvertTo-Json -Depth 20 | Set-Content -Path $reportPath -Encoding UTF8
    Write-Log ""
    Write-Log "Migration report written to: $reportPath" -Level SUCCESS

    # Write wave-specific reports
    foreach ($wr in $waveResults) {
        $wavePath = Join-Path $OutputPath "migration-wave-$($wr.WaveNumber)-report.json"
        $wr | ConvertTo-Json -Depth 15 | Set-Content -Path $wavePath -Encoding UTF8
        Write-Log "  Wave $($wr.WaveNumber) report: $wavePath"
    }

    # Console summary
    Write-Banner "Migration Runbook Summary"
    Write-Log "Overall Status   : $overallStatus"
    Write-Log "Total Duration   : $([math]::Round($totalDuration.TotalSeconds, 1))s"
    Write-Log "VMs Migrated     : $migrated / $($allVMs.Count)"
    Write-Log "VMs Failed       : $failed"
    Write-Log "VMs Skipped      : $skipped"
    Write-Log ""

    foreach ($wr in $waveResults) {
        $icon = switch ($wr.Status) {
            "Completed"           { "[DONE]" }
            "CompletedWithErrors" { "[WARN]" }
            "Blocked"             { "[FAIL]" }
            "DryRun"              { "[DRY ]" }
        }
        $lvl = switch ($wr.Status) {
            "Completed"           { "SUCCESS" }
            "CompletedWithErrors" { "WARN" }
            "Blocked"             { "ERROR" }
            "DryRun"              { "INFO" }
        }
        $vmNames = ($wr.VMs | ForEach-Object { $_.VMName }) -join ", "
        Write-Log "  $icon Wave $($wr.WaveNumber) '$($wr.WaveName)': $vmNames ($($wr.DurationSeconds)s)" -Level $lvl
    }

    Write-Log ""
    Write-Log "All reports written to: $OutputPath" -Level SUCCESS
}
catch {
    Write-Log "FATAL: $($_.Exception.Message)" -Level ERROR
    Write-Log "Stack: $($_.ScriptStackTrace)" -Level ERROR
    exit 1
}
