# =============================================================================
# Azure Integration Services Configuration for AVS
# Harbor Retail - VMware to Azure VMware Solution Migration
# =============================================================================
#
# Deploys the azure-integration.bicep template and configures supporting
# Azure native services: DNS forwarding, private endpoint validation,
# Azure SQL Database, and Azure Blob Storage for application assets.
# =============================================================================

#Requires -Modules Az.Accounts, Az.Resources, Az.Network, Az.Dns, Az.Sql, Az.Storage

<#
.SYNOPSIS
    Configures Azure native service integration for AVS workloads.

.DESCRIPTION
    Deploys Private DNS zones, private endpoints (Azure SQL & Blob Storage),
    Azure Front Door, VNet peering, and NSG rules via Bicep. Then configures
    DNS forwarding from AVS NSX-T DNS to Azure Private DNS, validates private
    endpoint connectivity from AVS VMs, sets up Azure SQL Database as a future
    modernization target for DB01, and configures Azure Blob Storage for
    application assets.

.PARAMETER ResourceGroupName
    Resource group containing the AVS private cloud and integration resources.

.PARAMETER PrivateCloudName
    Name of the AVS private cloud.

.PARAMETER TransitVnetId
    Resource ID of the existing transit virtual network.

.PARAMETER SqlServerName
    Name of the Azure SQL logical server to create or reuse.

.PARAMETER StorageAccountName
    Name of the Azure Storage account to create or reuse.

.PARAMETER Location
    Azure region for all resources. Defaults to eastus.

.PARAMETER DnsForwarderIp
    IP address of the Azure DNS Private Resolver or forwarder VM in the transit
    VNet. AVS NSX-T DNS will forward to this address.

.PARAMETER Simulate
    Run in dry-run mode without making changes.

.EXAMPLE
    .\configure-azure-services.ps1 -ResourceGroupName rg-harbor-retail-avs `
        -PrivateCloudName pc-harbor-retail `
        -TransitVnetId "/subscriptions/.../vnet-harbor-retail-transit" `
        -SqlServerName sql-harbor-retail `
        -StorageAccountName stharborretail `
        -DnsForwarderIp 10.200.0.10 `
        -Simulate
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory = $true)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $true)]
    [string]$PrivateCloudName,

    [Parameter(Mandatory = $true)]
    [string]$TransitVnetId,

    [Parameter(Mandatory = $true)]
    [string]$SqlServerName,

    [Parameter(Mandatory = $true)]
    [string]$StorageAccountName,

    [Parameter()]
    [string]$Location = "eastus",

    [Parameter()]
    [string]$DnsForwarderIp = "10.200.0.10",

    [Parameter()]
    [string]$SqlAdminUser = "sqladmin",

    [Parameter()]
    [securestring]$SqlAdminPassword,

    [switch]$Simulate
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
# Validate prerequisites
# -----------------------------------------------------------------------------

function Test-Prerequisites {
    Write-Section "Validating Prerequisites"

    $context = Get-AzContext
    if (-not $context) {
        Write-Log "No Azure context. Run Connect-AzAccount first." "ERROR"
        throw "Not authenticated to Azure."
    }
    Write-Log "Subscription: $($context.Subscription.Name)" "SUCCESS"

    # Verify Bicep template exists
    $templatePath = Join-Path $PSScriptRoot "..\bicep\azure-integration.bicep"
    if (-not (Test-Path $templatePath)) {
        Write-Log "Bicep template not found at $templatePath" "ERROR"
        throw "Missing azure-integration.bicep."
    }
    Write-Log "  ✓ Bicep template found" "SUCCESS"

    # Verify resource group
    $rg = Get-AzResourceGroup -Name $ResourceGroupName -ErrorAction SilentlyContinue
    if (-not $rg) {
        Write-Log "Resource group '$ResourceGroupName' not found." "ERROR"
        throw "Resource group not found."
    }
    Write-Log "  ✓ Resource group '$ResourceGroupName' exists" "SUCCESS"

    Write-Log "All prerequisites validated." "SUCCESS"
}

# -----------------------------------------------------------------------------
# Deploy Bicep template
# -----------------------------------------------------------------------------

function Deploy-AzureIntegration {
    Write-Section "Deploying Azure Integration Bicep Template"

    $templatePath = Join-Path $PSScriptRoot "..\bicep\azure-integration.bicep"
    $deploymentName = "azure-integration-$(Get-Date -Format 'yyyyMMddHHmmss')"

    $params = @{
        location              = $Location
        resourceGroupName     = $ResourceGroupName
        transitVnetId         = $TransitVnetId
        sqlServerName         = $SqlServerName
        storageAccountName    = $StorageAccountName
    }

    if ($Simulate) {
        Write-Log "[Simulate] Would deploy template '$templatePath'." "WARN"
        Write-Log "[Simulate]   Deployment name  : $deploymentName" "WARN"
        Write-Log "[Simulate]   Parameters       :" "WARN"
        foreach ($key in $params.Keys) {
            Write-Log "[Simulate]     $($key.PadRight(24)) = $($params[$key])" "WARN"
        }
        return
    }

    Write-Log "Starting deployment '$deploymentName'..."
    $result = New-AzResourceGroupDeployment `
        -ResourceGroupName $ResourceGroupName `
        -Name $deploymentName `
        -TemplateFile $templatePath `
        -TemplateParameterObject $params `
        -Verbose

    if ($result.ProvisioningState -ne "Succeeded") {
        Write-Log "Deployment failed: $($result.ProvisioningState)" "ERROR"
        throw "Bicep deployment failed."
    }

    Write-Log "  ✓ Deployment '$deploymentName' succeeded" "SUCCESS"
    Write-Log "  Front Door endpoint: $($result.Outputs.frontDoorEndpointHostName.Value)" "INFO"

    $script:deploymentOutputs = $result.Outputs
}

# -----------------------------------------------------------------------------
# Configure DNS forwarding from AVS NSX-T to Azure Private DNS
# -----------------------------------------------------------------------------

function Set-DnsForwarding {
    Write-Section "Configuring DNS Forwarding (AVS NSX-T → Azure Private DNS)"

    $dnsZones = @(
        "privatelink.database.windows.net"
        "privatelink.blob.core.windows.net"
    )

    if ($Simulate) {
        Write-Log "[Simulate] Would configure NSX-T DNS forwarding to $DnsForwarderIp." "WARN"
        foreach ($zone in $dnsZones) {
            Write-Log "[Simulate]   Zone: $zone → forwarder $DnsForwarderIp" "WARN"
        }
        Write-Log "[Simulate] NSX-T DNS configuration requires vCenter/NSX-T API access." "WARN"
        Write-Log "[Simulate] Manual steps:" "WARN"
        Write-Log "[Simulate]   1. Open NSX-T Manager → Networking → DNS Services" "WARN"
        Write-Log "[Simulate]   2. Edit the default DNS service" "WARN"
        Write-Log "[Simulate]   3. Add conditional forwarder for each private-link zone" "WARN"
        Write-Log "[Simulate]   4. Set forwarder IP to $DnsForwarderIp" "WARN"
        return
    }

    # Verify the DNS forwarder is reachable on port 53
    Write-Log "Testing DNS forwarder connectivity at ${DnsForwarderIp}:53..."
    $tcpTest = Test-NetConnection -ComputerName $DnsForwarderIp -Port 53 -WarningAction SilentlyContinue
    if ($tcpTest.TcpTestSucceeded) {
        Write-Log "  ✓ DNS forwarder reachable at ${DnsForwarderIp}:53" "SUCCESS"
    } else {
        Write-Log "DNS forwarder at ${DnsForwarderIp}:53 is not reachable. Ensure it is deployed." "WARN"
    }

    # Document the NSX-T configuration (requires NSX-T API / vCenter, not Az modules)
    Write-Log "NSX-T DNS forwarding must be configured via NSX-T Manager or API:" "INFO"
    foreach ($zone in $dnsZones) {
        Write-Log "  Conditional forward: $zone → $DnsForwarderIp" "INFO"
    }
    Write-Log "Refer to harbor-retail-vmware/documentation/azure-integration-guide.md for detailed steps." "INFO"
}

# -----------------------------------------------------------------------------
# Validate private endpoint connectivity from AVS VMs
# -----------------------------------------------------------------------------

function Test-PrivateEndpointConnectivity {
    Write-Section "Validating Private Endpoint Connectivity"

    $endpoints = @(
        @{ Name = "Azure SQL"; Host = "${SqlServerName}.database.windows.net"; Port = 1433 }
        @{ Name = "Blob Storage"; Host = "${StorageAccountName}.blob.core.windows.net"; Port = 443 }
    )

    if ($Simulate) {
        foreach ($ep in $endpoints) {
            Write-Log "[Simulate] Would validate connectivity to $($ep.Name): $($ep.Host):$($ep.Port)" "WARN"
            Write-Log "[Simulate]   1. Resolve $($ep.Host) — expect private IP (10.210.1.x)" "WARN"
            Write-Log "[Simulate]   2. TCP connect to $($ep.Host):$($ep.Port)" "WARN"
        }
        return
    }

    $results = @()
    foreach ($ep in $endpoints) {
        Write-Log "Testing $($ep.Name): $($ep.Host):$($ep.Port)..."

        # DNS resolution check
        try {
            $dns = Resolve-DnsName -Name $ep.Host -Type A -ErrorAction Stop
            $resolvedIp = ($dns | Where-Object { $_.QueryType -eq 'A' } | Select-Object -First 1).IPAddress
            $isPrivate = $resolvedIp -match '^10\.'
            Write-Log "  DNS resolves to: $resolvedIp (private: $isPrivate)" $(if ($isPrivate) { "SUCCESS" } else { "WARN" })
        } catch {
            $resolvedIp = "FAILED"
            $isPrivate = $false
            Write-Log "  DNS resolution failed: $_" "ERROR"
        }

        # TCP connectivity check
        $tcpTest = Test-NetConnection -ComputerName $ep.Host -Port $ep.Port -WarningAction SilentlyContinue
        if ($tcpTest.TcpTestSucceeded) {
            Write-Log "  ✓ TCP connection succeeded" "SUCCESS"
        } else {
            Write-Log "  ✗ TCP connection failed" "ERROR"
        }

        $results += [PSCustomObject]@{
            Service       = $ep.Name
            Host          = $ep.Host
            ResolvedIP    = $resolvedIp
            PrivateIP     = $isPrivate
            TcpConnected  = $tcpTest.TcpTestSucceeded
        }
    }

    Write-Log "Connectivity results:" "INFO"
    $results | Format-Table -AutoSize | Out-String | ForEach-Object { Write-Host $_ }
}

# -----------------------------------------------------------------------------
# Set up Azure SQL Database (modernization target for DB01)
# -----------------------------------------------------------------------------

function Set-AzureSqlDatabase {
    Write-Section "Configuring Azure SQL Database (Future Target for DB01)"

    $databaseName = "sqldb-harbor-retail"

    if ($Simulate) {
        Write-Log "[Simulate] Would ensure Azure SQL Server '$SqlServerName' exists in $Location." "WARN"
        Write-Log "[Simulate] Would create database '$databaseName' (GeneralPurpose, 2 vCores)." "WARN"
        Write-Log "[Simulate] Would configure:" "WARN"
        Write-Log "[Simulate]   • Transparent Data Encryption (TDE) enabled" "WARN"
        Write-Log "[Simulate]   • Public network access disabled (private endpoint only)" "WARN"
        Write-Log "[Simulate]   • Long-term backup retention (weekly: 5 weeks)" "WARN"
        Write-Log "[Simulate]   • Auditing to storage account '$StorageAccountName'" "WARN"
        return
    }

    # Ensure SQL Server exists
    $server = Get-AzSqlServer -ResourceGroupName $ResourceGroupName -ServerName $SqlServerName -ErrorAction SilentlyContinue
    if (-not $server) {
        Write-Log "Creating Azure SQL Server '$SqlServerName'..."
        if (-not $SqlAdminPassword) {
            Write-Log "SqlAdminPassword is required to create a new SQL Server." "ERROR"
            throw "Missing SqlAdminPassword."
        }
        $server = New-AzSqlServer `
            -ResourceGroupName $ResourceGroupName `
            -ServerName $SqlServerName `
            -Location $Location `
            -SqlAdministratorCredentials ([PSCredential]::new($SqlAdminUser, $SqlAdminPassword)) `
            -MinimalTlsVersion "1.2" `
            -PublicNetworkAccess "Disabled"
        Write-Log "  ✓ SQL Server created" "SUCCESS"
    } else {
        Write-Log "  ✓ SQL Server '$SqlServerName' already exists" "SUCCESS"
    }

    # Ensure database exists
    $db = Get-AzSqlDatabase -ResourceGroupName $ResourceGroupName -ServerName $SqlServerName -DatabaseName $databaseName -ErrorAction SilentlyContinue
    if (-not $db) {
        Write-Log "Creating database '$databaseName' (GeneralPurpose, 2 vCores)..."
        New-AzSqlDatabase `
            -ResourceGroupName $ResourceGroupName `
            -ServerName $SqlServerName `
            -DatabaseName $databaseName `
            -Edition "GeneralPurpose" `
            -VCore 2 `
            -ComputeGeneration "Gen5" `
            -ComputeModel "Provisioned" | Out-Null
        Write-Log "  ✓ Database '$databaseName' created" "SUCCESS"
    } else {
        Write-Log "  ✓ Database '$databaseName' already exists" "SUCCESS"
    }

    # Configure long-term backup retention
    Write-Log "Setting long-term backup retention (weekly = 5 weeks)..."
    Set-AzSqlDatabaseBackupLongTermRetentionPolicy `
        -ResourceGroupName $ResourceGroupName `
        -ServerName $SqlServerName `
        -DatabaseName $databaseName `
        -WeeklyRetention "P5W" | Out-Null
    Write-Log "  ✓ Backup retention configured" "SUCCESS"
}

# -----------------------------------------------------------------------------
# Configure Azure Blob Storage for application assets
# -----------------------------------------------------------------------------

function Set-AzureBlobStorage {
    Write-Section "Configuring Azure Blob Storage for Application Assets"

    $containers = @("web-assets", "app-config", "db-backups")

    if ($Simulate) {
        Write-Log "[Simulate] Would ensure Storage account '$StorageAccountName' exists in $Location." "WARN"
        Write-Log "[Simulate] Would configure:" "WARN"
        Write-Log "[Simulate]   • SKU: Standard_LRS" "WARN"
        Write-Log "[Simulate]   • TLS 1.2 minimum" "WARN"
        Write-Log "[Simulate]   • Public access: disabled" "WARN"
        Write-Log "[Simulate]   • Blob versioning: enabled" "WARN"
        foreach ($c in $containers) {
            Write-Log "[Simulate]   • Container: $c" "WARN"
        }
        return
    }

    # Ensure storage account exists
    $sa = Get-AzStorageAccount -ResourceGroupName $ResourceGroupName -Name $StorageAccountName -ErrorAction SilentlyContinue
    if (-not $sa) {
        Write-Log "Creating Storage account '$StorageAccountName'..."
        $sa = New-AzStorageAccount `
            -ResourceGroupName $ResourceGroupName `
            -Name $StorageAccountName `
            -Location $Location `
            -SkuName "Standard_LRS" `
            -Kind "StorageV2" `
            -MinimumTlsVersion "TLS1_2" `
            -AllowBlobPublicAccess $false `
            -EnableHttpsTrafficOnly $true
        Write-Log "  ✓ Storage account created" "SUCCESS"
    } else {
        Write-Log "  ✓ Storage account '$StorageAccountName' already exists" "SUCCESS"
    }

    # Enable blob versioning
    Write-Log "Enabling blob versioning..."
    Update-AzStorageBlobServiceProperty `
        -ResourceGroupName $ResourceGroupName `
        -StorageAccountName $StorageAccountName `
        -IsVersioningEnabled $true | Out-Null
    Write-Log "  ✓ Blob versioning enabled" "SUCCESS"

    # Create containers
    $ctx = $sa.Context
    foreach ($containerName in $containers) {
        $existing = Get-AzStorageContainer -Name $containerName -Context $ctx -ErrorAction SilentlyContinue
        if (-not $existing) {
            New-AzStorageContainer -Name $containerName -Context $ctx -Permission Off | Out-Null
            Write-Log "  ✓ Container '$containerName' created" "SUCCESS"
        } else {
            Write-Log "  Container '$containerName' already exists" "INFO"
        }
    }
}

# -----------------------------------------------------------------------------
# Output summary
# -----------------------------------------------------------------------------

function Show-Summary {
    Write-Section "Azure Integration Summary"

    $summary = [ordered]@{
        "Resource Group"           = $ResourceGroupName
        "AVS Private Cloud"        = $PrivateCloudName
        "Transit VNet"             = ($TransitVnetId -split '/')[-1]
        "SQL Server"               = $SqlServerName
        "Storage Account"          = $StorageAccountName
        "DNS Forwarder IP"         = $DnsForwarderIp
        "Simulate Mode"            = $Simulate.ToString()
    }

    foreach ($key in $summary.Keys) {
        Write-Host "  $($key.PadRight(28)) : $($summary[$key])" -ForegroundColor White
    }

    Write-Host ""
    Write-Log "Azure integration configuration complete." "SUCCESS"
    Write-Log "Next steps:" "INFO"
    Write-Host "  1. Configure NSX-T DNS conditional forwarders (see documentation)" -ForegroundColor White
    Write-Host "  2. Validate private endpoint resolution from AVS VMs" -ForegroundColor White
    Write-Host "  3. Plan DB01 data migration to Azure SQL using DMS" -ForegroundColor White
    Write-Host "  4. Upload application assets to Blob Storage containers" -ForegroundColor White
    Write-Host "  5. Configure Azure Front Door origins for web tier" -ForegroundColor White
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------

try {
    Write-Host ""
    Write-Host "  Harbor Retail — Azure Integration Services Configuration" -ForegroundColor Magenta
    Write-Host ""

    Test-Prerequisites
    Deploy-AzureIntegration
    Set-DnsForwarding
    Test-PrivateEndpointConnectivity
    Set-AzureSqlDatabase
    Set-AzureBlobStorage
    Show-Summary

    exit 0
} catch {
    Write-Log "FATAL: $_" "ERROR"
    Write-Log $_.ScriptStackTrace "ERROR"
    exit 1
}
