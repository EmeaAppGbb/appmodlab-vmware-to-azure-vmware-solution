# =============================================================================
# ExpressRoute Configuration for AVS
# Harbor Retail - VMware to Azure VMware Solution Migration
# =============================================================================
#
# Configures ExpressRoute Global Reach between AVS and on-premises,
# creates authorization keys, and sets up the VNet gateway connection.
# =============================================================================

#Requires -Modules Az.Accounts, Az.Network, Az.VMware

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $true)]
    [string]$PrivateCloudName,

    [Parameter()]
    [string]$OnPremExpressRouteCircuitId,

    [Parameter()]
    [string]$OnPremExpressRoutePeeringLocation,

    [Parameter()]
    [string]$GlobalReachAuthKey,

    [Parameter()]
    [string]$GatewayName = "ergw-harbor-retail",

    [Parameter()]
    [string]$AuthorizationKeyName = "harbor-retail-vnet-auth",

    [Parameter()]
    [string]$GlobalReachPeerCidr = "10.50.0.0/29",

    [Parameter()]
    [switch]$SkipGlobalReach,

    [Parameter()]
    [switch]$SkipVnetConnection
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

    Write-Log "Retrieving AVS private cloud '$PrivateCloudName'..."
    $script:privateCloud = Get-AzVMwarePrivateCloud `
        -ResourceGroupName $ResourceGroupName `
        -Name $PrivateCloudName

    if (-not $script:privateCloud) {
        Write-Log "Private cloud '$PrivateCloudName' not found in '$ResourceGroupName'." "ERROR"
        throw "AVS private cloud not found."
    }
    Write-Log "  ✓ Private cloud found (state: $($script:privateCloud.ProvisioningState))" "SUCCESS"

    if ($script:privateCloud.ProvisioningState -ne "Succeeded") {
        Write-Log "Private cloud is not in 'Succeeded' state. Current: $($script:privateCloud.ProvisioningState)" "ERROR"
        throw "AVS private cloud not ready."
    }

    if (-not $SkipGlobalReach -and -not $OnPremExpressRouteCircuitId) {
        Write-Log "On-prem ExpressRoute circuit ID is required for Global Reach (use -SkipGlobalReach to skip)." "ERROR"
        throw "Missing on-prem ExpressRoute circuit ID."
    }

    Write-Log "All prerequisites validated." "SUCCESS"
}

# -----------------------------------------------------------------------------
# Create AVS ExpressRoute authorization key
# -----------------------------------------------------------------------------

function New-AvsAuthorizationKey {
    Write-Section "Creating AVS ExpressRoute Authorization Key"

    Write-Log "Authorization key name: $AuthorizationKeyName"

    # Check for existing key
    $existing = Get-AzVMwareAuthorization `
        -ResourceGroupName $ResourceGroupName `
        -PrivateCloudName $PrivateCloudName `
        -Name $AuthorizationKeyName `
        -ErrorAction SilentlyContinue

    if ($existing) {
        Write-Log "Authorization key '$AuthorizationKeyName' already exists." "WARN"
        $script:authKey = $existing
    } else {
        Write-Log "Creating new authorization key..."
        $script:authKey = New-AzVMwareAuthorization `
            -ResourceGroupName $ResourceGroupName `
            -PrivateCloudName $PrivateCloudName `
            -Name $AuthorizationKeyName

        Write-Log "  ✓ Authorization key created" "SUCCESS"
    }

    Write-Log "  Key ID : $($script:authKey.Id)"
}

# -----------------------------------------------------------------------------
# Configure ExpressRoute Global Reach
# -----------------------------------------------------------------------------

function Set-GlobalReach {
    Write-Section "Configuring ExpressRoute Global Reach"

    if ($SkipGlobalReach) {
        Write-Log "Global Reach configuration skipped (-SkipGlobalReach)." "WARN"
        return
    }

    $avsCircuitId = $script:privateCloud.CircuitExpressRouteId
    if (-not $avsCircuitId) {
        Write-Log "AVS ExpressRoute circuit ID not available on the private cloud resource." "ERROR"
        throw "Cannot determine AVS ExpressRoute circuit ID."
    }
    Write-Log "AVS ER circuit     : $avsCircuitId"
    Write-Log "On-prem ER circuit : $OnPremExpressRouteCircuitId"
    Write-Log "Peer address CIDR  : $GlobalReachPeerCidr"

    # Create Global Reach connection via Azure CLI (Az PowerShell module does not
    # expose Global Reach natively on the AVS resource)
    Write-Log "Establishing Global Reach peering..."

    $grArgs = @(
        "vmware", "private-cloud", "add-global-reach-connection",
        "--resource-group", $ResourceGroupName,
        "--name", $PrivateCloudName,
        "--peer-express-route-circuit", $OnPremExpressRouteCircuitId,
        "--peer-express-route-connection", $GlobalReachPeerCidr
    )
    if ($GlobalReachAuthKey) {
        $grArgs += @("--authorization-key", $GlobalReachAuthKey)
    }

    $output = az @grArgs 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Log "Global Reach configuration failed: $output" "ERROR"
        throw "Failed to configure Global Reach."
    }

    Write-Log "  ✓ Global Reach peering established" "SUCCESS"

    # Verify
    Write-Log "Verifying Global Reach connections..."
    $grList = az vmware private-cloud list-global-reach-connections `
        --resource-group $ResourceGroupName `
        --name $PrivateCloudName `
        --output json 2>&1 | ConvertFrom-Json

    if ($grList) {
        foreach ($gr in $grList) {
            Write-Log "  Connection: $($gr.name) — Status: $($gr.circuitConnectionStatus)" "INFO"
        }
    }
}

# -----------------------------------------------------------------------------
# Configure VNet gateway connection
# -----------------------------------------------------------------------------

function Set-VnetGatewayConnection {
    Write-Section "Configuring VNet Gateway Connection"

    if ($SkipVnetConnection) {
        Write-Log "VNet gateway connection skipped (-SkipVnetConnection)." "WARN"
        return
    }

    $gateway = Get-AzVirtualNetworkGateway `
        -ResourceGroupName $ResourceGroupName `
        -Name $GatewayName `
        -ErrorAction SilentlyContinue

    if (-not $gateway) {
        Write-Log "ExpressRoute gateway '$GatewayName' not found in '$ResourceGroupName'." "ERROR"
        throw "Gateway not found."
    }
    Write-Log "  ✓ Gateway found: $($gateway.Name) (state: $($gateway.ProvisioningState))" "SUCCESS"

    $avsCircuitId = $script:privateCloud.CircuitExpressRouteId
    $authKeyValue = $script:authKey.ExpressRouteAuthorizationKey

    $connectionName = "conn-$PrivateCloudName-vnet"

    # Check for existing connection
    $existingConn = Get-AzVirtualNetworkGatewayConnection `
        -ResourceGroupName $ResourceGroupName `
        -Name $connectionName `
        -ErrorAction SilentlyContinue

    if ($existingConn) {
        Write-Log "Connection '$connectionName' already exists (state: $($existingConn.ConnectionStatus))." "WARN"
        return
    }

    Write-Log "Creating ExpressRoute connection '$connectionName'..."
    Write-Log "  Gateway  : $($gateway.Id)"
    Write-Log "  Circuit  : $avsCircuitId"

    New-AzVirtualNetworkGatewayConnection `
        -ResourceGroupName $ResourceGroupName `
        -Name $connectionName `
        -Location $gateway.Location `
        -VirtualNetworkGateway1 $gateway `
        -ConnectionType ExpressRoute `
        -ExpressRouteCircuitId $avsCircuitId `
        -AuthorizationKey $authKeyValue `
        -RoutingWeight 0 | Out-Null

    Write-Log "  ✓ VNet gateway connection created" "SUCCESS"

    # Verify connection
    Write-Log "Verifying connection status..."
    $retries = 0
    $maxRetries = 10
    while ($retries -lt $maxRetries) {
        Start-Sleep -Seconds 15
        $conn = Get-AzVirtualNetworkGatewayConnection `
            -ResourceGroupName $ResourceGroupName `
            -Name $connectionName
        if ($conn.ConnectionStatus -eq "Connected") {
            Write-Log "  ✓ Connection status: Connected" "SUCCESS"
            return
        }
        $retries++
        Write-Log "  Connection status: $($conn.ConnectionStatus) (attempt $retries/$maxRetries)"
    }

    Write-Log "Connection created but not yet in 'Connected' state. It may take additional time." "WARN"
}

# -----------------------------------------------------------------------------
# Output summary
# -----------------------------------------------------------------------------

function Show-Summary {
    Write-Section "ExpressRoute Configuration Summary"

    $avsCircuitId = $script:privateCloud.CircuitExpressRouteId

    $summary = [ordered]@{
        "Private Cloud"              = $PrivateCloudName
        "Resource Group"             = $ResourceGroupName
        "AVS ER Circuit"             = $avsCircuitId
        "Authorization Key"          = $AuthorizationKeyName
        "Global Reach Configured"    = (-not $SkipGlobalReach).ToString()
        "VNet Connection Configured" = (-not $SkipVnetConnection).ToString()
    }

    if (-not $SkipGlobalReach) {
        $summary["On-Prem ER Circuit"] = $OnPremExpressRouteCircuitId
        $summary["Global Reach Peer CIDR"] = $GlobalReachPeerCidr
    }

    foreach ($key in $summary.Keys) {
        Write-Host "  $($key.PadRight(28)) : $($summary[$key])" -ForegroundColor White
    }

    Write-Host ""
    Write-Log "ExpressRoute configuration complete." "SUCCESS"
    Write-Log "Next steps:" "INFO"
    Write-Host "  1. Verify connectivity from on-premises to AVS management network" -ForegroundColor White
    Write-Host "  2. Confirm vCenter and NSX-T Manager are reachable" -ForegroundColor White
    Write-Host "  3. Proceed with HCX configuration for workload migration" -ForegroundColor White
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------

try {
    Write-Host ""
    Write-Host "  Harbor Retail — ExpressRoute Configuration for AVS" -ForegroundColor Magenta
    Write-Host ""

    Test-Prerequisites
    New-AvsAuthorizationKey
    Set-GlobalReach
    Set-VnetGatewayConnection
    Show-Summary

    exit 0
} catch {
    Write-Log "FATAL: $_" "ERROR"
    Write-Log $_.ScriptStackTrace "ERROR"
    exit 1
}
