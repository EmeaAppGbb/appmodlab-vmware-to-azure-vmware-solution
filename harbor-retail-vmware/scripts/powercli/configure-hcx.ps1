<#
.SYNOPSIS
    Automates VMware HCX setup for the Harbor Retail VMware-to-AVS migration.

.DESCRIPTION
    End-to-end HCX deployment and configuration automation including:

    1. Activate HCX add-on on the AVS private cloud (via Azure CLI)
    2. Download and deploy HCX Connector OVA to on-premises vCenter
    3. Configure site pairing between on-prem HCX Connector and AVS HCX Cloud Manager
    4. Create network profiles (management, vMotion, uplink)
    5. Create compute profiles for source and destination sites
    6. Deploy a service mesh linking the two sites
    7. Validate tunnel status and end-to-end connectivity

    In simulation mode (-Simulate) all external calls are replaced with
    realistic delays and deterministic success responses, making it safe
    for lab, demo, and CI/CD environments.

.PARAMETER VCenterServer
    Source on-premises vCenter Server FQDN or IP address.

.PARAMETER AVSPrivateCloudName
    Name of the Azure VMware Solution private cloud resource.

.PARAMETER AVSResourceGroup
    Azure resource group containing the AVS private cloud.

.PARAMETER HCXActivationKey
    HCX activation/license key for the on-premises connector.

.PARAMETER AVSHCXCloudManagerUrl
    FQDN of the HCX Cloud Manager endpoint on AVS (e.g., hcx.avs.azure.com).

.PARAMETER NetworkProfilePath
    Path to hcx-network-profiles.json. Defaults to the file alongside this script.

.PARAMETER Credential
    PSCredential for vCenter / HCX authentication (live mode).

.PARAMETER OutputPath
    Directory for configuration reports. Defaults to .\output.

.PARAMETER Simulate
    Run the entire workflow using simulated operations. No external
    connections are made.

.PARAMETER SkipAVSActivation
    Skip the AVS HCX add-on activation step (use when already activated).

.PARAMETER HCXConnectorOvaPath
    Local path to a pre-downloaded HCX Connector OVA. When omitted the
    script downloads the OVA from the AVS portal.

.EXAMPLE
    .\configure-hcx.ps1 -VCenterServer vcenter.harbor.local `
        -AVSPrivateCloudName Harbor-AVS-PrivateCloud `
        -AVSResourceGroup Harbor-AVS-RG `
        -Simulate
    Runs the full HCX setup workflow in simulation mode.

.EXAMPLE
    .\configure-hcx.ps1 -VCenterServer vcenter.harbor.local `
        -AVSPrivateCloudName Harbor-AVS-PrivateCloud `
        -AVSResourceGroup Harbor-AVS-RG `
        -HCXActivationKey "XXXXX-XXXXX-XXXXX" `
        -AVSHCXCloudManagerUrl hcx-cloud.avs.azure.com `
        -Credential (Get-Credential)
    Performs live HCX setup with prompted credentials.

.NOTES
    Author  : Harbor Retail Platform Engineering
    Requires: PowerShell 5.1+, VMware PowerCLI 13.0+, Azure CLI 2.50+
    Version : 1.0.0
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, HelpMessage = "Source vCenter FQDN or IP")]
    [ValidateNotNullOrEmpty()]
    [string]$VCenterServer,

    [Parameter(Mandatory = $true, HelpMessage = "AVS private cloud name")]
    [ValidateNotNullOrEmpty()]
    [string]$AVSPrivateCloudName,

    [Parameter(Mandatory = $true, HelpMessage = "AVS resource group")]
    [ValidateNotNullOrEmpty()]
    [string]$AVSResourceGroup,

    [Parameter(Mandatory = $false, HelpMessage = "HCX activation key")]
    [string]$HCXActivationKey,

    [Parameter(Mandatory = $false, HelpMessage = "AVS HCX Cloud Manager URL")]
    [string]$AVSHCXCloudManagerUrl = "hcx-cloud.avs.azure.com",

    [Parameter(Mandatory = $false, HelpMessage = "Path to network profiles JSON")]
    [string]$NetworkProfilePath,

    [Parameter(Mandatory = $false, HelpMessage = "PSCredential for authentication")]
    [PSCredential]$Credential,

    [Parameter(Mandatory = $false, HelpMessage = "Output directory for reports")]
    [string]$OutputPath = ".\output",

    [Parameter(Mandatory = $false, HelpMessage = "Run in simulation mode")]
    [switch]$Simulate,

    [Parameter(Mandatory = $false, HelpMessage = "Skip AVS HCX activation")]
    [switch]$SkipAVSActivation,

    [Parameter(Mandatory = $false, HelpMessage = "Path to pre-downloaded HCX OVA")]
    [string]$HCXConnectorOvaPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$script:StartTime = Get-Date
$script:ConfigLog = [System.Collections.ArrayList]::new()

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
    [void]$script:ConfigLog.Add([ordered]@{
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

function New-OutputDirectory {
    if (-not (Test-Path $OutputPath)) {
        New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
        Write-Log "Created output directory: $OutputPath"
    }
}

# ---------------------------------------------------------------------------
# Network profile loader
# ---------------------------------------------------------------------------

function Get-NetworkProfiles {
    <#
    .SYNOPSIS
        Loads HCX network profile definitions from JSON configuration.
    #>
    $profilePath = if ($NetworkProfilePath) {
        $NetworkProfilePath
    } else {
        Join-Path $PSScriptRoot "hcx-network-profiles.json"
    }

    if (-not (Test-Path $profilePath)) {
        throw "Network profile configuration not found at: $profilePath"
    }

    Write-Log "Loading network profiles from: $profilePath"
    $config = Get-Content -Path $profilePath -Raw | ConvertFrom-Json
    return $config.networkProfiles
}

# ---------------------------------------------------------------------------
# Step 1 — Activate HCX on AVS Private Cloud
# ---------------------------------------------------------------------------

function Enable-AVSHCXAddon {
    <#
    .SYNOPSIS
        Activates the HCX add-on on the AVS private cloud via Azure CLI.
    #>
    Write-Banner "Step 1: Activate HCX on AVS Private Cloud"

    if ($SkipAVSActivation) {
        Write-Log "Skipping AVS HCX activation (-SkipAVSActivation specified)" -Level "WARN"
        return [ordered]@{
            Step      = "AVS HCX Activation"
            Status    = "Skipped"
            Message   = "Activation skipped by parameter"
        }
    }

    if ($Simulate) {
        Write-Log "SIMULATION: Activating HCX add-on on $AVSPrivateCloudName"
        Start-Sleep -Seconds 2
        Write-Log "SIMULATION: HCX add-on activation initiated" -Level "SUCCESS"
        Start-Sleep -Seconds 3
        Write-Log "SIMULATION: HCX add-on status: Succeeded" -Level "SUCCESS"
        return [ordered]@{
            Step      = "AVS HCX Activation"
            Status    = "Succeeded"
            Cloud     = $AVSPrivateCloudName
            Simulated = $true
        }
    }

    Write-Log "Activating HCX add-on on AVS private cloud: $AVSPrivateCloudName"
    try {
        $result = az vmware addon hcx create `
            --resource-group $AVSResourceGroup `
            --private-cloud $AVSPrivateCloudName `
            --offer "VMware MaaS Cloud Provider" `
            --output json 2>&1

        if ($LASTEXITCODE -ne 0) {
            throw "Azure CLI returned exit code $LASTEXITCODE`: $result"
        }

        Write-Log "Waiting for HCX add-on provisioning to complete..."
        $maxWait = 600   # 10 minutes
        $elapsed = 0
        $interval = 30
        while ($elapsed -lt $maxWait) {
            Start-Sleep -Seconds $interval
            $elapsed += $interval
            $status = az vmware addon hcx show `
                --resource-group $AVSResourceGroup `
                --private-cloud $AVSPrivateCloudName `
                --query "provisioningState" -o tsv 2>&1
            Write-Log "HCX provisioning state: $status (${elapsed}s elapsed)"
            if ($status -eq "Succeeded") { break }
        }

        if ($status -ne "Succeeded") {
            throw "HCX activation did not complete within $maxWait seconds. Last status: $status"
        }

        Write-Log "HCX add-on activated successfully" -Level "SUCCESS"
        return [ordered]@{
            Step      = "AVS HCX Activation"
            Status    = "Succeeded"
            Cloud     = $AVSPrivateCloudName
            Simulated = $false
        }
    }
    catch {
        Write-Log "Failed to activate HCX: $_" -Level "ERROR"
        throw
    }
}

# ---------------------------------------------------------------------------
# Step 2 — Download and Deploy HCX Connector OVA
# ---------------------------------------------------------------------------

function Deploy-HCXConnector {
    <#
    .SYNOPSIS
        Downloads (if needed) and deploys the HCX Connector OVA to on-premises vCenter.
    #>
    Write-Banner "Step 2: Deploy HCX Connector OVA"

    if ($Simulate) {
        Write-Log "SIMULATION: Downloading HCX Connector OVA from AVS portal"
        Start-Sleep -Seconds 2
        Write-Log "SIMULATION: Deploying HCX Connector OVA to $VCenterServer"
        Start-Sleep -Seconds 3
        Write-Log "SIMULATION: HCX Connector VM powered on at hcx-connector.harbor.local" -Level "SUCCESS"
        Start-Sleep -Seconds 2
        Write-Log "SIMULATION: Activating HCX Connector with license key" -Level "SUCCESS"
        return [ordered]@{
            Step               = "Deploy HCX Connector"
            Status             = "Succeeded"
            ConnectorFQDN      = "hcx-connector.harbor.local"
            ConnectorIP        = "10.10.0.50"
            VCenter            = $VCenterServer
            Simulated          = $true
        }
    }

    # Resolve OVA path — download from AVS if not provided
    $ovaPath = $HCXConnectorOvaPath
    if (-not $ovaPath) {
        Write-Log "Retrieving HCX Connector download URL from AVS..."
        $downloadUrl = az vmware addon hcx show `
            --resource-group $AVSResourceGroup `
            --private-cloud $AVSPrivateCloudName `
            --query "properties.hcxConnectorOvaUrl" -o tsv 2>&1

        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($downloadUrl)) {
            throw "Unable to retrieve HCX Connector OVA download URL"
        }

        $ovaPath = Join-Path $OutputPath "VMware-HCX-Connector.ova"
        Write-Log "Downloading HCX Connector OVA to $ovaPath"
        Invoke-WebRequest -Uri $downloadUrl -OutFile $ovaPath -UseBasicParsing
        Write-Log "Download complete" -Level "SUCCESS"
    }

    if (-not (Test-Path $ovaPath)) {
        throw "HCX Connector OVA not found at: $ovaPath"
    }

    # Deploy via PowerCLI OVF import
    Write-Log "Connecting to vCenter: $VCenterServer"
    Connect-VIServer -Server $VCenterServer -Credential $Credential -ErrorAction Stop | Out-Null

    $ovfConfig = Get-OvfConfiguration -Ovf $ovaPath
    $vmHost = Get-VMHost | Select-Object -First 1
    $datastore = Get-Datastore | Sort-Object FreeSpaceGB -Descending | Select-Object -First 1

    Write-Log "Deploying OVA to host $($vmHost.Name), datastore $($datastore.Name)"
    $vm = Import-VApp -Source $ovaPath -OvfConfiguration $ovfConfig `
        -VMHost $vmHost -Datastore $datastore -Name "HCX-Connector" -ErrorAction Stop

    Start-VM -VM $vm -Confirm:$false | Out-Null
    Write-Log "HCX Connector VM deployed and powered on" -Level "SUCCESS"

    # Activate the connector
    Write-Log "Activating HCX Connector with license key"
    $activationBody = @{ activationKey = $HCXActivationKey } | ConvertTo-Json
    $connectorIp = ($vm | Get-VMGuest).IPAddress | Select-Object -First 1
    Invoke-RestMethod -Uri "https://$connectorIp`:443/api/admin/global/config/hcx" `
        -Method POST -Body $activationBody -ContentType "application/json" `
        -SkipCertificateCheck

    Write-Log "HCX Connector activated successfully" -Level "SUCCESS"
    Disconnect-VIServer -Confirm:$false -ErrorAction SilentlyContinue

    return [ordered]@{
        Step               = "Deploy HCX Connector"
        Status             = "Succeeded"
        ConnectorIP        = $connectorIp
        VCenter            = $VCenterServer
        Simulated          = $false
    }
}

# ---------------------------------------------------------------------------
# Step 3 — Configure Site Pairing
# ---------------------------------------------------------------------------

function New-HCXSitePairing {
    <#
    .SYNOPSIS
        Creates a site pairing between the on-prem HCX Connector and AVS HCX Cloud Manager.
    #>
    Write-Banner "Step 3: Configure Site Pairing"

    $connectorUrl = "hcx-connector.harbor.local"

    if ($Simulate) {
        Write-Log "SIMULATION: Initiating site pairing"
        Write-Log "  Source  : $connectorUrl (on-premises)"
        Write-Log "  Remote  : $AVSHCXCloudManagerUrl (AVS)"
        Start-Sleep -Seconds 3
        Write-Log "SIMULATION: Site pairing established" -Level "SUCCESS"
        return [ordered]@{
            Step        = "Site Pairing"
            Status      = "Succeeded"
            LocalSite   = $connectorUrl
            RemoteSite  = $AVSHCXCloudManagerUrl
            PairingId   = "sp-harbor-avs-001"
            Simulated   = $true
        }
    }

    Write-Log "Creating site pairing: $connectorUrl <-> $AVSHCXCloudManagerUrl"
    try {
        $pairingBody = @{
            remote = @{
                url      = "https://$AVSHCXCloudManagerUrl"
                userName = $Credential.UserName
                password = $Credential.GetNetworkCredential().Password
            }
        } | ConvertTo-Json -Depth 5

        $response = Invoke-RestMethod `
            -Uri "https://${connectorUrl}:443/api/admin/global/config/hcx/sitePairing" `
            -Method POST -Body $pairingBody -ContentType "application/json" `
            -SkipCertificateCheck

        Write-Log "Site pairing created (ID: $($response.data.pairingId))" -Level "SUCCESS"
        return [ordered]@{
            Step        = "Site Pairing"
            Status      = "Succeeded"
            LocalSite   = $connectorUrl
            RemoteSite  = $AVSHCXCloudManagerUrl
            PairingId   = $response.data.pairingId
            Simulated   = $false
        }
    }
    catch {
        Write-Log "Site pairing failed: $_" -Level "ERROR"
        throw
    }
}

# ---------------------------------------------------------------------------
# Step 4 — Create Network Profiles
# ---------------------------------------------------------------------------

function New-HCXNetworkProfiles {
    <#
    .SYNOPSIS
        Creates HCX network profiles for management, vMotion, and uplink networks.
    #>
    Write-Banner "Step 4: Create Network Profiles"

    $profiles = Get-NetworkProfiles
    $results = @()

    foreach ($profileType in @("management", "vMotion", "uplink")) {
        $np = $profiles.$profileType
        Write-Log "Creating network profile: $($np.name) ($profileType)"
        Write-Log "  Network  : $($np.networkCIDR)"
        Write-Log "  Gateway  : $($np.gateway)"
        Write-Log "  IP Pool  : $($np.ipPools[0].startAddress) - $($np.ipPools[0].endAddress)"
        Write-Log "  MTU      : $($np.mtu)"
        Write-Log "  DNS      : $($np.dns.primary), $($np.dns.secondary)"

        if ($Simulate) {
            Start-Sleep -Milliseconds 800
            Write-Log "SIMULATION: Network profile '$($np.name)' created" -Level "SUCCESS"
            $results += [ordered]@{
                ProfileName = $np.name
                Type        = $profileType
                Network     = $np.networkCIDR
                Status      = "Created"
                Simulated   = $true
            }
            continue
        }

        try {
            $npBody = @{
                name            = $np.name
                networks        = @(@{
                    name        = $np.networkName
                    backing     = @{ type = "DistributedVirtualPortgroup" }
                })
                ipScopes        = @(@{
                    gateway       = $np.gateway
                    prefixLength  = $np.prefixLength
                    primaryDns    = $np.dns.primary
                    secondaryDns  = $np.dns.secondary
                    dnsSuffix     = $np.dns.searchDomains[0]
                    ipPools       = @(@{
                        startAddress = $np.ipPools[0].startAddress
                        endAddress   = $np.ipPools[0].endAddress
                    })
                })
                mtu             = $np.mtu
            } | ConvertTo-Json -Depth 10

            $connectorUrl = "hcx-connector.harbor.local"
            Invoke-RestMethod `
                -Uri "https://${connectorUrl}:443/api/admin/global/config/hcx/networkProfiles" `
                -Method POST -Body $npBody -ContentType "application/json" `
                -SkipCertificateCheck

            Write-Log "Network profile '$($np.name)' created" -Level "SUCCESS"
            $results += [ordered]@{
                ProfileName = $np.name
                Type        = $profileType
                Network     = $np.networkCIDR
                Status      = "Created"
                Simulated   = $false
            }
        }
        catch {
            Write-Log "Failed to create network profile '$($np.name)': $_" -Level "ERROR"
            throw
        }
    }

    return $results
}

# ---------------------------------------------------------------------------
# Step 5 — Create Compute Profiles
# ---------------------------------------------------------------------------

function New-HCXComputeProfiles {
    <#
    .SYNOPSIS
        Creates source and destination compute profiles for HCX.
    #>
    Write-Banner "Step 5: Create Compute Profiles"

    $computeProfiles = @(
        [ordered]@{
            Name        = "Harbor-OnPrem-ComputeProfile"
            Site        = "Source"
            Cluster     = "Harbor-Production"
            Datastore   = "vsanDatastore"
            Description = "On-premises Harbor Retail compute resources"
        },
        [ordered]@{
            Name        = "Harbor-AVS-ComputeProfile"
            Site        = "Destination"
            Cluster     = "Cluster-1"
            Datastore   = "vsanDatastore"
            Description = "AVS destination compute resources"
        }
    )

    $results = @()

    foreach ($cp in $computeProfiles) {
        Write-Log "Creating compute profile: $($cp.Name) ($($cp.Site))"
        Write-Log "  Cluster   : $($cp.Cluster)"
        Write-Log "  Datastore : $($cp.Datastore)"

        if ($Simulate) {
            Start-Sleep -Milliseconds 800
            Write-Log "SIMULATION: Compute profile '$($cp.Name)' created" -Level "SUCCESS"
            $results += [ordered]@{
                ProfileName = $cp.Name
                Site        = $cp.Site
                Status      = "Created"
                Simulated   = $true
            }
            continue
        }

        try {
            $cpBody = @{
                name           = $cp.Name
                cluster        = @{ name = $cp.Cluster }
                datastore      = @{ name = $cp.Datastore }
                deploymentType = "Standard"
                services       = @(
                    @{ name = "INTERCONNECT" },
                    @{ name = "VMOTION" },
                    @{ name = "BULK_MIGRATION" },
                    @{ name = "NETWORK_EXTENSION" },
                    @{ name = "DISASTER_RECOVERY" }
                )
            } | ConvertTo-Json -Depth 10

            $connectorUrl = "hcx-connector.harbor.local"
            Invoke-RestMethod `
                -Uri "https://${connectorUrl}:443/api/admin/global/config/hcx/computeProfiles" `
                -Method POST -Body $cpBody -ContentType "application/json" `
                -SkipCertificateCheck

            Write-Log "Compute profile '$($cp.Name)' created" -Level "SUCCESS"
            $results += [ordered]@{
                ProfileName = $cp.Name
                Site        = $cp.Site
                Status      = "Created"
                Simulated   = $false
            }
        }
        catch {
            Write-Log "Failed to create compute profile '$($cp.Name)': $_" -Level "ERROR"
            throw
        }
    }

    return $results
}

# ---------------------------------------------------------------------------
# Step 6 — Deploy Service Mesh
# ---------------------------------------------------------------------------

function New-HCXServiceMesh {
    <#
    .SYNOPSIS
        Deploys an HCX service mesh between source and destination sites.
    #>
    Write-Banner "Step 6: Deploy Service Mesh"

    $meshName = "Harbor-ServiceMesh"
    Write-Log "Deploying service mesh: $meshName"
    Write-Log "  Source Compute Profile : Harbor-OnPrem-ComputeProfile"
    Write-Log "  Dest Compute Profile   : Harbor-AVS-ComputeProfile"
    Write-Log "  Services               : Interconnect, vMotion, Bulk Migration, Network Extension"

    if ($Simulate) {
        Write-Log "SIMULATION: Validating network profiles for service mesh..."
        Start-Sleep -Seconds 1
        Write-Log "SIMULATION: Deploying HCX Interconnect (IX) appliance..."
        Start-Sleep -Seconds 3
        Write-Log "SIMULATION: Deploying HCX Network Extension (NE) appliance..."
        Start-Sleep -Seconds 2
        Write-Log "SIMULATION: Establishing tunnels..."
        Start-Sleep -Seconds 3
        Write-Log "SIMULATION: Service mesh '$meshName' deployed" -Level "SUCCESS"
        return [ordered]@{
            Step                   = "Service Mesh Deployment"
            MeshName               = $meshName
            Status                 = "Succeeded"
            SourceComputeProfile   = "Harbor-OnPrem-ComputeProfile"
            DestComputeProfile     = "Harbor-AVS-ComputeProfile"
            Appliances             = @("IX-Appliance", "NE-Appliance")
            TunnelStatus           = "Up"
            Simulated              = $true
        }
    }

    try {
        $meshBody = @{
            name                 = $meshName
            sourceComputeProfile = "Harbor-OnPrem-ComputeProfile"
            destComputeProfile   = "Harbor-AVS-ComputeProfile"
            services             = @(
                @{ name = "INTERCONNECT" },
                @{ name = "VMOTION" },
                @{ name = "BULK_MIGRATION" },
                @{ name = "NETWORK_EXTENSION" }
            )
            networkProfiles      = @{
                management = "HCX-Management-NetworkProfile"
                vMotion    = "HCX-vMotion-NetworkProfile"
                uplink     = "HCX-Uplink-NetworkProfile"
            }
        } | ConvertTo-Json -Depth 10

        $connectorUrl = "hcx-connector.harbor.local"
        $response = Invoke-RestMethod `
            -Uri "https://${connectorUrl}:443/api/admin/global/config/hcx/serviceMesh" `
            -Method POST -Body $meshBody -ContentType "application/json" `
            -SkipCertificateCheck

        # Wait for service mesh deployment
        Write-Log "Service mesh deployment initiated, waiting for completion..."
        $maxWait = 900   # 15 minutes
        $elapsed = 0
        $interval = 30
        while ($elapsed -lt $maxWait) {
            Start-Sleep -Seconds $interval
            $elapsed += $interval
            $status = Invoke-RestMethod `
                -Uri "https://${connectorUrl}:443/api/admin/global/config/hcx/serviceMesh/$($response.data.meshId)/status" `
                -Method GET -ContentType "application/json" `
                -SkipCertificateCheck
            Write-Log "Service mesh status: $($status.data.state) (${elapsed}s)"
            if ($status.data.state -eq "READY") { break }
        }

        if ($status.data.state -ne "READY") {
            throw "Service mesh did not reach READY state within $maxWait seconds"
        }

        Write-Log "Service mesh '$meshName' deployed successfully" -Level "SUCCESS"
        return [ordered]@{
            Step                   = "Service Mesh Deployment"
            MeshName               = $meshName
            Status                 = "Succeeded"
            SourceComputeProfile   = "Harbor-OnPrem-ComputeProfile"
            DestComputeProfile     = "Harbor-AVS-ComputeProfile"
            Simulated              = $false
        }
    }
    catch {
        Write-Log "Service mesh deployment failed: $_" -Level "ERROR"
        throw
    }
}

# ---------------------------------------------------------------------------
# Step 7 — Validate Tunnel Status
# ---------------------------------------------------------------------------

function Test-HCXTunnelStatus {
    <#
    .SYNOPSIS
        Validates HCX tunnel health and connectivity between sites.
    #>
    Write-Banner "Step 7: Validate Tunnel Status"

    if ($Simulate) {
        Write-Log "SIMULATION: Checking Interconnect tunnel..."
        Start-Sleep -Seconds 1
        Write-Log "SIMULATION: Interconnect tunnel: UP" -Level "SUCCESS"
        Write-Log "SIMULATION: Checking vMotion reachability..."
        Start-Sleep -Seconds 1
        Write-Log "SIMULATION: vMotion reachability: OK" -Level "SUCCESS"
        Write-Log "SIMULATION: Checking Network Extension status..."
        Start-Sleep -Seconds 1
        Write-Log "SIMULATION: Network Extension: UP" -Level "SUCCESS"

        $tunnelResults = [ordered]@{
            Step     = "Tunnel Validation"
            Status   = "Healthy"
            Tunnels  = @(
                [ordered]@{ Name = "Interconnect";      Status = "UP"; Latency = "5ms" }
                [ordered]@{ Name = "vMotion";           Status = "UP"; Latency = "3ms" }
                [ordered]@{ Name = "Network Extension"; Status = "UP"; Latency = "4ms" }
            )
            Simulated = $true
        }

        Write-Log "All tunnels healthy — HCX is ready for migration" -Level "SUCCESS"
        return $tunnelResults
    }

    try {
        $connectorUrl = "hcx-connector.harbor.local"
        $tunnels = Invoke-RestMethod `
            -Uri "https://${connectorUrl}:443/api/admin/global/config/hcx/tunnelStatus" `
            -Method GET -ContentType "application/json" `
            -SkipCertificateCheck

        $allUp = $true
        $tunnelDetails = @()
        foreach ($tunnel in $tunnels.data) {
            $isUp = $tunnel.status -eq "UP"
            $level = if ($isUp) { "SUCCESS" } else { "ERROR" }
            Write-Log "$($tunnel.name) tunnel: $($tunnel.status)" -Level $level
            if (-not $isUp) { $allUp = $false }
            $tunnelDetails += [ordered]@{
                Name    = $tunnel.name
                Status  = $tunnel.status
                Latency = $tunnel.latency
            }
        }

        $overallStatus = if ($allUp) { "Healthy" } else { "Degraded" }
        if (-not $allUp) {
            Write-Log "One or more tunnels are not UP — check connectivity" -Level "WARN"
        } else {
            Write-Log "All tunnels healthy — HCX is ready for migration" -Level "SUCCESS"
        }

        return [ordered]@{
            Step      = "Tunnel Validation"
            Status    = $overallStatus
            Tunnels   = $tunnelDetails
            Simulated = $false
        }
    }
    catch {
        Write-Log "Tunnel validation failed: $_" -Level "ERROR"
        throw
    }
}

# ---------------------------------------------------------------------------
# Main Orchestrator
# ---------------------------------------------------------------------------

function Invoke-HCXSetup {
    <#
    .SYNOPSIS
        Orchestrates the full HCX setup pipeline.
    #>
    Write-Banner "Harbor Retail — HCX Configuration Automation"
    Write-Log "Mode: $(if ($Simulate) { 'SIMULATION' } else { 'LIVE' })"
    Write-Log "vCenter Server     : $VCenterServer"
    Write-Log "AVS Private Cloud  : $AVSPrivateCloudName"
    Write-Log "AVS Resource Group : $AVSResourceGroup"
    Write-Log "HCX Cloud Manager  : $AVSHCXCloudManagerUrl"
    Write-Host ""

    New-OutputDirectory

    $report = [ordered]@{
        Metadata = [ordered]@{
            ScriptName    = "configure-hcx.ps1"
            Version       = "1.0.0"
            ExecutedAt    = (Get-Date -Format "o")
            Mode          = if ($Simulate) { "Simulation" } else { "Live" }
            VCenterServer = $VCenterServer
            AVSCloud      = $AVSPrivateCloudName
        }
        Steps = [ordered]@{}
    }

    try {
        # Step 1 — Activate HCX on AVS
        $report.Steps["1_AVS_Activation"] = Enable-AVSHCXAddon

        # Step 2 — Deploy HCX Connector
        $report.Steps["2_HCX_Connector"] = Deploy-HCXConnector

        # Step 3 — Site Pairing
        $report.Steps["3_Site_Pairing"] = New-HCXSitePairing

        # Step 4 — Network Profiles
        $report.Steps["4_Network_Profiles"] = New-HCXNetworkProfiles

        # Step 5 — Compute Profiles
        $report.Steps["5_Compute_Profiles"] = New-HCXComputeProfiles

        # Step 6 — Service Mesh
        $report.Steps["6_Service_Mesh"] = New-HCXServiceMesh

        # Step 7 — Tunnel Validation
        $report.Steps["7_Tunnel_Validation"] = Test-HCXTunnelStatus

        Write-Banner "HCX Setup Complete"
        Write-Log "All steps completed successfully" -Level "SUCCESS"
    }
    catch {
        Write-Log "HCX setup failed at step: $_" -Level "ERROR"
        $report.Error = $_.ToString()
    }
    finally {
        $report.Log = $script:ConfigLog.ToArray()
        $report.Duration = "{0:N1} minutes" -f ((Get-Date) - $script:StartTime).TotalMinutes

        $reportFile = Join-Path $OutputPath "hcx-setup-report.json"
        $report | ConvertTo-Json -Depth 20 | Set-Content -Path $reportFile -Encoding UTF8
        Write-Log "Report saved to: $reportFile"
    }

    return $report
}

# ---------------------------------------------------------------------------
# Entry Point
# ---------------------------------------------------------------------------

Invoke-HCXSetup
