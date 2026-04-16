#Requires -Modules Az.RecoveryServices, Az.Compute

<#
.SYNOPSIS
    Configures Azure Backup for AVS-migrated VMs with tiered policies.

.DESCRIPTION
    Creates a Recovery Services vault (if not exists), applies custom backup policies
    (daily for web/app tiers, hourly for database tier), enables protection for each
    VM, validates backup status, and produces a summary report.

.PARAMETER ResourceGroupName
    Resource group containing the AVS private cloud and target VMs.

.PARAMETER VaultName
    Name of the Recovery Services vault to create or reuse.

.PARAMETER Location
    Azure region for the vault. Defaults to eastus.

.PARAMETER Simulate
    Run in dry-run mode without making changes.

.EXAMPLE
    .\configure-backup.ps1 -ResourceGroupName rg-avs -VaultName rsv-avs -Simulate
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory = $true)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $true)]
    [string]$VaultName,

    [Parameter(Mandatory = $false)]
    [string]$Location = "eastus",

    [switch]$Simulate
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

# ---------------------------------------------------------------------------
# VM tier definitions — each tier gets its own backup policy
# ---------------------------------------------------------------------------
$vmTiers = @{
    WebApp = @{
        VMs              = @("WEB01", "WEB02", "APP01", "APP02")
        PolicyName       = "DailyPolicy-WebApp"
        ScheduleRunFrequency = "Daily"
        RetentionDays    = 30
        Description      = "Daily backup, 30-day retention"
    }
    Database = @{
        VMs              = @("DB01")
        PolicyName       = "HourlyPolicy-DB"
        ScheduleRunFrequency = "Hourly"
        HourInterval     = 4
        HourDuration     = 24
        RetentionDays    = 90
        Description      = "Every-4-hour backup, 90-day retention"
    }
}

$report = [System.Collections.Generic.List[PSCustomObject]]::new()

function Write-Step  { param([string]$Msg) Write-Host "  » $Msg" -ForegroundColor Cyan }
function Write-Ok    { param([string]$Msg) Write-Host "  ✓ $Msg" -ForegroundColor Green }
function Write-Warn  { param([string]$Msg) Write-Host "  ⚠ $Msg" -ForegroundColor Yellow }
function Write-Err   { param([string]$Msg) Write-Host "  ✗ $Msg" -ForegroundColor Red }

# ---------------------------------------------------------------------------
# 1. Recovery Services Vault — create if it does not exist
# ---------------------------------------------------------------------------
Write-Host "`n=== Recovery Services Vault ===" -ForegroundColor White
Write-Step "Checking for existing vault '$VaultName'..."

$vault = Get-AzRecoveryServicesVault -ResourceGroupName $ResourceGroupName -Name $VaultName -ErrorAction SilentlyContinue

if ($vault) {
    Write-Ok "Vault '$VaultName' already exists."
} else {
    if ($Simulate) {
        Write-Warn "[Simulate] Would create vault '$VaultName' in $Location."
    } else {
        Write-Step "Creating vault '$VaultName' in $Location..."
        try {
            $vault = New-AzRecoveryServicesVault `
                -ResourceGroupName $ResourceGroupName `
                -Name $VaultName `
                -Location $Location
            Write-Ok "Vault created successfully."
        } catch {
            Write-Err "Failed to create vault: $_"
            throw
        }
    }
}

if (-not $Simulate) {
    Set-AzRecoveryServicesAsBackupVaultContext -Vault $vault
}

# ---------------------------------------------------------------------------
# 2. Create / retrieve backup policies per tier
# ---------------------------------------------------------------------------
Write-Host "`n=== Backup Policies ===" -ForegroundColor White

$policies = @{}

foreach ($tierName in $vmTiers.Keys) {
    $tier = $vmTiers[$tierName]
    $policyName = $tier.PolicyName

    Write-Step "Processing policy '$policyName' ($($tier.Description))..."

    if ($Simulate) {
        Write-Warn "[Simulate] Would create/ensure policy '$policyName'."
        continue
    }

    $existingPolicy = Get-AzRecoveryServicesBackupProtectionPolicy -Name $policyName -ErrorAction SilentlyContinue

    if ($existingPolicy) {
        Write-Ok "Policy '$policyName' already exists."
        $policies[$tierName] = $existingPolicy
    } else {
        try {
            $schedulePolicy  = Get-AzRecoveryServicesBackupSchedulePolicyObject -WorkloadType AzureVM
            $retentionPolicy = Get-AzRecoveryServicesBackupRetentionPolicyObject -WorkloadType AzureVM

            if ($tier.ScheduleRunFrequency -eq "Hourly") {
                $schedulePolicy.ScheduleRunFrequency      = "Hourly"
                $schedulePolicy.HourlySchedule.Interval    = $tier.HourInterval
                $schedulePolicy.HourlySchedule.WindowDuration = $tier.HourDuration
            } else {
                $schedulePolicy.ScheduleRunFrequency = "Daily"
                $schedulePolicy.ScheduleRunTimes[0]  = (Get-Date "02:00").ToUniversalTime()
            }

            $retentionPolicy.DailySchedule.DurationCountInDays = $tier.RetentionDays

            $newPolicy = New-AzRecoveryServicesBackupProtectionPolicy `
                -Name $policyName `
                -WorkloadType AzureVM `
                -SchedulePolicy $schedulePolicy `
                -RetentionPolicy $retentionPolicy

            Write-Ok "Policy '$policyName' created."
            $policies[$tierName] = $newPolicy
        } catch {
            Write-Err "Failed to create policy '$policyName': $_"
            throw
        }
    }
}

# ---------------------------------------------------------------------------
# 3. Enable protection for each VM
# ---------------------------------------------------------------------------
Write-Host "`n=== Enable Backup Protection ===" -ForegroundColor White

foreach ($tierName in $vmTiers.Keys) {
    $tier = $vmTiers[$tierName]
    $policyName = $tier.PolicyName

    foreach ($vmName in $tier.VMs) {
        Write-Step "Enabling backup for $vmName (policy: $policyName)..."

        if ($Simulate) {
            Write-Warn "[Simulate] Would enable backup for $vmName with policy $policyName."
            $report.Add([PSCustomObject]@{
                VM        = $vmName
                Tier      = $tierName
                Policy    = $policyName
                Status    = "Simulated"
                Validated = "N/A"
            })
            continue
        }

        try {
            $vm = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $vmName -ErrorAction Stop
            $policy = $policies[$tierName]

            Enable-AzRecoveryServicesBackupProtection `
                -ResourceGroupName $ResourceGroupName `
                -Policy $policy `
                -Name $vmName `
                -VaultId $vault.ID | Out-Null

            Write-Ok "Backup enabled for $vmName."

            # --- Validate backup status ---
            $backupItem = Get-AzRecoveryServicesBackupItem `
                -WorkloadType AzureVM `
                -BackupManagementType AzureVM `
                -VaultId $vault.ID |
                Where-Object { $_.Name -like "*$vmName*" }

            $validated = if ($backupItem -and $backupItem.ProtectionState -eq "Protected") {
                Write-Ok "Backup validated for $vmName — state: Protected."
                "Pass"
            } else {
                Write-Warn "Backup validation pending for $vmName (initial backup not yet run)."
                "Pending"
            }

            $report.Add([PSCustomObject]@{
                VM        = $vmName
                Tier      = $tierName
                Policy    = $policyName
                Status    = "Enabled"
                Validated = $validated
            })
        } catch {
            Write-Err "Failed to enable backup for ${vmName}: $_"
            $report.Add([PSCustomObject]@{
                VM        = $vmName
                Tier      = $tierName
                Policy    = $policyName
                Status    = "FAILED"
                Validated = "N/A"
            })
        }
    }
}

# ---------------------------------------------------------------------------
# 4. Status report
# ---------------------------------------------------------------------------
Write-Host "`n=== Backup Configuration Report ===" -ForegroundColor White
$report | Format-Table -AutoSize

$failedCount = ($report | Where-Object { $_.Status -eq "FAILED" }).Count
if ($failedCount -gt 0) {
    Write-Err "$failedCount VM(s) failed backup configuration — review errors above."
    exit 1
} else {
    Write-Ok "All VMs processed successfully."
}

Write-Host "`nBackup configuration complete!`n" -ForegroundColor Green
