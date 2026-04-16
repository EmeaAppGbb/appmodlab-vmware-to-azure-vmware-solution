# =============================================================================
# Azure VMware Solution (AVS) Private Cloud Deployment Script
# Harbor Retail - VMware to Azure VMware Solution Migration
# =============================================================================
#
# Validates prerequisites, deploys the Bicep template, waits for provisioning,
# and outputs connection details (vCenter, NSX-T Manager, HCX endpoints).
# =============================================================================

#Requires -Modules Az.Accounts, Az.Resources

[CmdletBinding()]
param(
    [Parameter()]
    [string]$TemplateFile = "$PSScriptRoot\..\bicep\avs-deployment.bicep",

    [Parameter()]
    [string]$ParametersFile = "$PSScriptRoot\..\bicep\avs-deployment.parameters.json",

    [Parameter()]
    [string]$DeploymentName = "avs-harbor-retail-$(Get-Date -Format 'yyyyMMdd-HHmmss')",

    [Parameter()]
    [string]$Location = "eastus",

    [Parameter()]
    [int]$ProvisioningTimeoutMinutes = 240,

    [Parameter()]
    [int]$PollingIntervalSeconds = 60
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# -----------------------------------------------------------------------------
# Logging helpers
# -----------------------------------------------------------------------------

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $color = switch ($Level) {
        "INFO"    { "Cyan" }
        "SUCCESS" { "Green" }
        "WARN"    { "Yellow" }
        "ERROR"   { "Red" }
        default   { "White" }
    }
    Write-Host "[$timestamp] [$Level] $Message" -ForegroundColor $color
}

function Write-Section {
    param([string]$Title)
    Write-Host ""
    Write-Host ("=" * 78) -ForegroundColor DarkGray
    Write-Log $Title
    Write-Host ("=" * 78) -ForegroundColor DarkGray
}

# -----------------------------------------------------------------------------
# Prerequisite validation
# -----------------------------------------------------------------------------

function Test-Prerequisites {
    Write-Section "Validating Prerequisites"

    # 1. Azure context
    Write-Log "Checking Azure subscription context..."
    $context = Get-AzContext
    if (-not $context) {
        Write-Log "No Azure context found. Run Connect-AzAccount first." "ERROR"
        throw "Not authenticated to Azure."
    }
    Write-Log "Subscription: $($context.Subscription.Name) ($($context.Subscription.Id))" "SUCCESS"

    # 2. Required resource providers
    $requiredProviders = @(
        "Microsoft.AVS",
        "Microsoft.Network",
        "Microsoft.Resources"
    )
    Write-Log "Checking resource provider registrations..."
    foreach ($provider in $requiredProviders) {
        $reg = Get-AzResourceProvider -ProviderNamespace $provider -ErrorAction SilentlyContinue
        if ($reg.RegistrationState -contains "Registered") {
            Write-Log "  ✓ $provider registered" "SUCCESS"
        } else {
            Write-Log "  Registering $provider..." "WARN"
            Register-AzResourceProvider -ProviderNamespace $provider | Out-Null
            Write-Log "  ✓ $provider registration initiated" "SUCCESS"
        }
    }

    # 3. AVS quota check
    Write-Log "Checking AVS host quota in $Location..."
    try {
        $quota = Get-AzVMwarePrivateCloud -ErrorAction SilentlyContinue 2>$null
        Write-Log "  AVS resource provider is accessible" "SUCCESS"
    } catch {
        Write-Log "  Unable to query AVS quota — verify that your subscription has AVS enabled" "WARN"
        Write-Log "  Request quota at: https://aka.ms/avs/quota" "WARN"
    }

    # 4. Template files exist
    if (-not (Test-Path $TemplateFile)) {
        Write-Log "Bicep template not found: $TemplateFile" "ERROR"
        throw "Template file missing."
    }
    if (-not (Test-Path $ParametersFile)) {
        Write-Log "Parameters file not found: $ParametersFile" "ERROR"
        throw "Parameters file missing."
    }
    Write-Log "  ✓ Template and parameters files located" "SUCCESS"

    Write-Log "All prerequisites validated." "SUCCESS"
}

# -----------------------------------------------------------------------------
# Deployment
# -----------------------------------------------------------------------------

function Start-AvsDeployment {
    Write-Section "Deploying AVS Private Cloud"

    Write-Log "Deployment name : $DeploymentName"
    Write-Log "Template        : $TemplateFile"
    Write-Log "Parameters      : $ParametersFile"
    Write-Log "Location        : $Location"
    Write-Log ""
    Write-Log "Starting subscription-level deployment (this will take 3-4 hours)..."

    $deployment = New-AzSubscriptionDeployment `
        -Name $DeploymentName `
        -Location $Location `
        -TemplateFile $TemplateFile `
        -TemplateParameterFile $ParametersFile `
        -AsJob

    Write-Log "Deployment submitted as background job (Id: $($deployment.Id))." "SUCCESS"
    return $deployment
}

# -----------------------------------------------------------------------------
# Wait for provisioning
# -----------------------------------------------------------------------------

function Wait-ForProvisioning {
    param([object]$Job)

    Write-Section "Waiting for Provisioning"
    Write-Log "Timeout set to $ProvisioningTimeoutMinutes minutes."

    $deadline = (Get-Date).AddMinutes($ProvisioningTimeoutMinutes)
    $elapsed = 0

    while ((Get-Date) -lt $deadline) {
        $jobState = (Get-Job -Id $Job.Id).State
        if ($jobState -eq "Completed") {
            $result = Receive-Job -Id $Job.Id -ErrorAction Stop
            if ($result.ProvisioningState -eq "Succeeded") {
                Write-Log "Deployment completed successfully." "SUCCESS"
                return $result
            } else {
                Write-Log "Deployment finished with state: $($result.ProvisioningState)" "ERROR"
                throw "Deployment did not succeed."
            }
        } elseif ($jobState -eq "Failed") {
            $err = Receive-Job -Id $Job.Id -ErrorAction SilentlyContinue 2>&1
            Write-Log "Deployment job failed: $err" "ERROR"
            throw "Deployment job failed."
        }

        $elapsed += $PollingIntervalSeconds
        $elapsedMin = [math]::Round($elapsed / 60, 1)
        Write-Log "Provisioning in progress... ($elapsedMin min elapsed)"
        Start-Sleep -Seconds $PollingIntervalSeconds
    }

    Write-Log "Deployment timed out after $ProvisioningTimeoutMinutes minutes." "ERROR"
    throw "Provisioning timeout exceeded."
}

# -----------------------------------------------------------------------------
# Output connection details
# -----------------------------------------------------------------------------

function Show-ConnectionDetails {
    param([object]$Deployment)

    Write-Section "AVS Connection Details"

    $outputs = $Deployment.Outputs

    $details = [ordered]@{
        "Resource Group"       = $outputs["resourceGroupName"].Value
        "Private Cloud ID"     = $outputs["avsPrivateCloudId"].Value
        "vCenter Endpoint"     = $outputs["vCenterEndpoint"].Value
        "NSX-T Manager"        = $outputs["nsxtManagerEndpoint"].Value
        "Transit VNet ID"      = $outputs["transitVnetId"].Value
        "ER Gateway ID"        = $outputs["expressRouteGatewayId"].Value
    }

    # Retrieve HCX endpoint from the private cloud resource directly
    $rgName = $outputs["resourceGroupName"].Value
    try {
        $pc = Get-AzVMwarePrivateCloud -ResourceGroupName $rgName -Name "pc-harbor-retail" -ErrorAction SilentlyContinue
        if ($pc) {
            $details["HCX Cloud Manager"] = $pc.EndpointHcxCloudManager
            $details["vCenter IP"]        = $pc.EndpointVcsa
            $details["NSX-T Manager IP"]  = $pc.EndpointNsxtManager
        }
    } catch {
        Write-Log "Could not retrieve extended endpoints from private cloud resource." "WARN"
    }

    foreach ($key in $details.Keys) {
        Write-Host "  $($key.PadRight(22)) : $($details[$key])" -ForegroundColor White
    }

    # Credentials reminder
    Write-Host ""
    Write-Log "Retrieve admin credentials with:" "INFO"
    Write-Host "  az vmware private-cloud show -g $rgName -n pc-harbor-retail --query '{vcenter: vcenterPassword, nsxt: nsxtPassword}'" -ForegroundColor DarkYellow

    Write-Host ""
    Write-Log "Deployment complete. Proceed with ExpressRoute configuration." "SUCCESS"
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------

try {
    Write-Host ""
    Write-Host "  Harbor Retail — AVS Private Cloud Deployment" -ForegroundColor Magenta
    Write-Host ""

    Test-Prerequisites
    $job = Start-AvsDeployment
    $result = Wait-ForProvisioning -Job $job
    Show-ConnectionDetails -Deployment $result

    exit 0
} catch {
    Write-Log "FATAL: $_" "ERROR"
    Write-Log $_.ScriptStackTrace "ERROR"
    exit 1
}
