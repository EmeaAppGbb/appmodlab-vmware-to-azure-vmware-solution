<#
.SYNOPSIS
    Assesses VMware environment compatibility with Azure VMware Solution (AVS).

.DESCRIPTION
    Reads inventory data produced by export-inventory.ps1 and evaluates every VM
    and infrastructure component against AVS compatibility requirements:

    - vSphere / ESXi version compatibility
    - VM hardware version support (vmx-13 through vmx-21)
    - VMware Tools version and running status
    - Snapshot presence (must be removed before HCX migration)
    - Network adapter type validation (VMXNET3 recommended)
    - Disk controller / storage format checks
    - CPU and memory sizing against AVS node SKUs
    - AVS capacity planning (node count, cluster sizing)
    - NSX-V to NSX-T migration considerations

    Generates a detailed JSON compatibility report with per-VM pass/fail/warn
    status and an overall environment readiness score.

.PARAMETER InventoryPath
    Path to the consolidated vcenter-inventory-export.json file produced by
    export-inventory.ps1. If omitted, looks for .\output\vcenter-inventory-export.json.

.PARAMETER OutputPath
    Directory where the compatibility report JSON is written.
    Defaults to .\output.

.PARAMETER Simulate
    When specified, generates an inventory internally and assesses it, without
    requiring a prior export. Useful for demos and testing.

.PARAMETER AVSNodeSKU
    The AVS host SKU to use for capacity planning calculations.
    Supported: AV36, AV36P, AV52. Default: AV36P.

.PARAMETER ReservedCapacityPercent
    Percentage of AVS cluster capacity to reserve for HA failover.
    Default is 25 (one node in a four-node minimum cluster). VMware/Azure
    best practice is N+1 host reservation.

.EXAMPLE
    .\assess-compatibility.ps1 -Simulate
    Runs a full compatibility assessment against simulated Harbor Retail data.

.EXAMPLE
    .\assess-compatibility.ps1 -InventoryPath .\output\vcenter-inventory-export.json -AVSNodeSKU AV36P
    Reads a real inventory export and sizes for AV36P nodes.

.NOTES
    Author  : Harbor Retail Platform Engineering
    Requires: PowerShell 5.1+
    Version : 1.0.0
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false, HelpMessage = "Path to inventory export JSON")]
    [string]$InventoryPath,

    [Parameter(Mandatory = $false, HelpMessage = "Output directory for reports")]
    [string]$OutputPath = ".\output",

    [Parameter(Mandatory = $false, HelpMessage = "Run against simulated data")]
    [switch]$Simulate,

    [Parameter(Mandatory = $false, HelpMessage = "AVS node SKU for capacity planning")]
    [ValidateSet("AV36", "AV36P", "AV52")]
    [string]$AVSNodeSKU = "AV36P",

    [Parameter(Mandatory = $false, HelpMessage = "Percent of cluster capacity reserved for HA")]
    [ValidateRange(0, 50)]
    [int]$ReservedCapacityPercent = 25
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$script:StartTime = Get-Date

# ---------------------------------------------------------------------------
# Logging & progress helpers
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
}

function Write-ProgressStep {
    param([string]$Activity, [string]$Status, [int]$PercentComplete)
    Write-Progress -Activity $Activity -Status $Status -PercentComplete $PercentComplete
}

# ---------------------------------------------------------------------------
# AVS node SKU definitions
# ---------------------------------------------------------------------------

function Get-AVSNodeSpec {
    <#
    .SYNOPSIS
        Returns CPU, memory, and storage specifications for the given AVS host SKU.
    #>
    param([string]$SKU)
    $specs = @{
        "AV36"  = @{ Cores = 36; MemoryGB = 576;  StorageTB = 15.36; Description = "AV36 - Intel Xeon Gold 6140 (Skylake)" }
        "AV36P" = @{ Cores = 36; MemoryGB = 768;  StorageTB = 19.20; Description = "AV36P - Intel Xeon Gold 6240 (Cascade Lake)" }
        "AV52"  = @{ Cores = 52; MemoryGB = 1536; StorageTB = 38.40; Description = "AV52 - Intel Xeon Platinum 8270 (Cascade Lake)" }
    }
    return $specs[$SKU]
}

# ---------------------------------------------------------------------------
# Compatibility check functions
# ---------------------------------------------------------------------------

function Test-VSphereVersion {
    <#
    .SYNOPSIS
        Validates that the source vSphere version is supported for HCX migration.
        HCX supports vSphere 5.1+ but 6.5+ is recommended.
    #>
    param([hashtable]$Inventory)

    $result = @{
        Check       = "vSphere Version Compatibility"
        Status      = "Pass"
        Details     = ""
        Findings    = @()
    }

    # Infer version from hardware versions present
    $hwVersions = $Inventory.VirtualMachines | ForEach-Object { $_.HardwareVersion } | Sort-Object -Unique
    $result.Findings += "Hardware versions detected: $($hwVersions -join ', ')"

    foreach ($hwv in $hwVersions) {
        $versionNum = 0
        if ($hwv -match 'vmx-(\d+)') { $versionNum = [int]$Matches[1] }

        if ($versionNum -lt 13) {
            $result.Status = "Fail"
            $result.Findings += "Hardware version $hwv maps to vSphere < 6.5 — upgrade required"
        }
        elseif ($versionNum -lt 17) {
            if ($result.Status -ne "Fail") { $result.Status = "Warn" }
            $result.Findings += "Hardware version $hwv maps to vSphere 6.5/6.7 — supported but upgrade recommended"
        }
        else {
            $result.Findings += "Hardware version $hwv maps to vSphere 7.0+ — fully supported"
        }
    }

    $result.Details = "HCX requires vSphere 5.1+ (6.5+ recommended). All VMs should be vmx-13 or higher."
    return $result
}

function Test-VMHardwareVersions {
    <#
    .SYNOPSIS
        Checks each VM's virtual hardware version against AVS-supported range.
        AVS supports vmx-13 (vSphere 6.5) through vmx-21 (vSphere 8.0 U3).
    #>
    param([array]$VMs)

    $result = @{
        Check    = "VM Hardware Version Compatibility"
        Status   = "Pass"
        Details  = "AVS supports virtual hardware versions vmx-13 through vmx-21."
        Findings = @()
        VMResults = @()
    }

    foreach ($vm in $VMs) {
        $versionNum = 0
        if ($vm.HardwareVersion -match 'vmx-(\d+)') { $versionNum = [int]$Matches[1] }

        $vmResult = @{
            VMName          = $vm.Name
            HardwareVersion = $vm.HardwareVersion
            Status          = "Pass"
            Message         = ""
        }

        if ($versionNum -lt 13) {
            $vmResult.Status  = "Fail"
            $vmResult.Message = "Hardware version $($vm.HardwareVersion) is below minimum (vmx-13). Upgrade required."
            $result.Status    = "Fail"
        }
        elseif ($versionNum -gt 21) {
            $vmResult.Status  = "Warn"
            $vmResult.Message = "Hardware version $($vm.HardwareVersion) exceeds tested range. Verify compatibility."
            if ($result.Status -ne "Fail") { $result.Status = "Warn" }
        }
        else {
            $vmResult.Message = "Hardware version $($vm.HardwareVersion) is supported."
        }

        $result.VMResults += $vmResult
    }

    $passCount = @($result.VMResults | Where-Object { $_.Status -eq "Pass" }).Count
    $result.Findings += "$passCount of $($VMs.Count) VMs have compatible hardware versions."
    return $result
}

function Test-VMwareTools {
    <#
    .SYNOPSIS
        Validates VMware Tools installation and running status on each VM.
        Tools must be running for HCX vMotion and Bulk Migration.
    #>
    param([array]$VMs)

    $result = @{
        Check    = "VMware Tools Status"
        Status   = "Pass"
        Details  = "VMware Tools must be installed and running for HCX migration."
        Findings = @()
        VMResults = @()
    }

    foreach ($vm in $VMs) {
        $vmResult = @{
            VMName       = $vm.Name
            ToolsVersion = $vm.VMToolsVersion
            ToolsStatus  = $vm.VMToolsStatus
            Status       = "Pass"
            Message      = ""
        }

        if (-not $vm.VMToolsVersion -or $vm.VMToolsVersion -eq "") {
            $vmResult.Status  = "Fail"
            $vmResult.Message = "VMware Tools not installed."
            $result.Status    = "Fail"
        }
        elseif ($vm.VMToolsStatus -ne "toolsOk") {
            $vmResult.Status  = "Warn"
            $vmResult.Message = "VMware Tools installed ($($vm.VMToolsVersion)) but status is $($vm.VMToolsStatus). Remediate before migration."
            if ($result.Status -ne "Fail") { $result.Status = "Warn" }
        }
        else {
            $vmResult.Message = "VMware Tools $($vm.VMToolsVersion) running normally."
        }

        $result.VMResults += $vmResult
    }

    $okCount = @($result.VMResults | Where-Object { $_.Status -eq "Pass" }).Count
    $result.Findings += "$okCount of $($VMs.Count) VMs have VMware Tools running correctly."
    return $result
}

function Test-Snapshots {
    <#
    .SYNOPSIS
        Checks for VM snapshots that must be removed before HCX migration.
        HCX vMotion does not support VMs with snapshots.
    #>
    param([array]$VMs)

    $result = @{
        Check    = "Snapshot Check"
        Status   = "Pass"
        Details  = "VMs with snapshots cannot be migrated via HCX vMotion. Snapshots must be removed or consolidated."
        Findings = @()
        VMResults = @()
    }

    foreach ($vm in $VMs) {
        $snapCount = if ($vm.Snapshots) { $vm.Snapshots.Count } else { 0 }
        $vmResult = @{
            VMName        = $vm.Name
            SnapshotCount = $snapCount
            Status        = "Pass"
            Message       = ""
            Snapshots     = @()
        }

        if ($snapCount -gt 0) {
            $vmResult.Status    = "Fail"
            $vmResult.Message   = "$snapCount snapshot(s) found. Remove before migration."
            $vmResult.Snapshots = $vm.Snapshots
            $result.Status      = "Fail"
            $result.Findings   += "$($vm.Name): $snapCount snapshot(s) must be removed."
        }
        else {
            $vmResult.Message = "No snapshots — ready for migration."
        }

        $result.VMResults += $vmResult
    }

    $cleanCount = @($result.VMResults | Where-Object { $_.Status -eq "Pass" }).Count
    $result.Findings += "$cleanCount of $($VMs.Count) VMs are snapshot-free."
    return $result
}

function Test-NetworkAdapters {
    <#
    .SYNOPSIS
        Validates network adapter types. VMXNET3 is required for optimal
        performance on AVS. E1000/E1000E adapters should be upgraded.
    #>
    param([array]$VMs)

    $result = @{
        Check    = "Network Adapter Compatibility"
        Status   = "Pass"
        Details  = "VMXNET3 adapters are recommended for AVS. E1000/E1000E adapters work but may impact performance."
        Findings = @()
        VMResults = @()
    }

    foreach ($vm in $VMs) {
        $vmResult = @{
            VMName   = $vm.Name
            Adapters = @()
            Status   = "Pass"
            Message  = ""
        }

        foreach ($nic in $vm.NetworkAdapters) {
            $adapterResult = @{
                Name   = $nic.Name
                Type   = $nic.Type
                Status = "Pass"
            }

            if ($nic.Type -eq "Vmxnet3") {
                $adapterResult.Status = "Pass"
            }
            elseif ($nic.Type -match "E1000") {
                $adapterResult.Status = "Warn"
                if ($vmResult.Status -ne "Fail") { $vmResult.Status = "Warn" }
                if ($result.Status -ne "Fail") { $result.Status = "Warn" }
            }
            else {
                $adapterResult.Status = "Warn"
                if ($vmResult.Status -ne "Fail") { $vmResult.Status = "Warn" }
            }

            $vmResult.Adapters += $adapterResult
        }

        $vmResult.Message = if ($vmResult.Status -eq "Pass") {
            "All adapters are VMXNET3."
        } else {
            "Non-VMXNET3 adapters detected. Consider upgrading."
        }

        $result.VMResults += $vmResult
    }

    $vmxnet3Count = @($result.VMResults | Where-Object { $_.Status -eq "Pass" }).Count
    $result.Findings += "$vmxnet3Count of $($VMs.Count) VMs use VMXNET3 exclusively."
    return $result
}

function Test-DiskConfiguration {
    <#
    .SYNOPSIS
        Validates disk sizes and formats against AVS / vSAN limits.
        Maximum VMDK size on vSAN is 62 TB. Thick-provisioned disks are
        converted to thin on vSAN.
    #>
    param([array]$VMs)

    $maxVMDKSizeTB = 62

    $result = @{
        Check    = "Disk Configuration"
        Status   = "Pass"
        Details  = "AVS vSAN supports VMDKs up to $($maxVMDKSizeTB) TB. All formats are stored as vSAN objects."
        Findings = @()
        VMResults = @()
    }

    foreach ($vm in $VMs) {
        $vmResult = @{
            VMName = $vm.Name
            Disks  = @()
            Status = "Pass"
        }

        foreach ($disk in $vm.Disks) {
            $diskResult = @{
                Label      = $disk.Label
                CapacityGB = $disk.CapacityGB
                Format     = $disk.StorageFormat
                Status     = "Pass"
                Message    = ""
            }

            if ($disk.CapacityGB -gt ($maxVMDKSizeTB * 1024)) {
                $diskResult.Status  = "Fail"
                $diskResult.Message = "Disk exceeds $($maxVMDKSizeTB) TB vSAN limit."
                $vmResult.Status    = "Fail"
                $result.Status      = "Fail"
            }
            else {
                $diskResult.Message = "Size within limits."
            }

            $vmResult.Disks += $diskResult
        }

        $result.VMResults += $vmResult
    }

    $passCount = @($result.VMResults | Where-Object { $_.Status -eq "Pass" }).Count
    $result.Findings += "$passCount of $($VMs.Count) VMs have compatible disk configurations."
    return $result
}

function Get-AVSCapacityRequirements {
    <#
    .SYNOPSIS
        Calculates the number of AVS nodes required based on aggregate VM
        resource consumption and the selected host SKU.
    #>
    param(
        [array]$VMs,
        [string]$SKU,
        [int]$ReservedPercent
    )

    $nodeSpec = Get-AVSNodeSpec -SKU $SKU

    # Aggregate resource demand
    $totalvCPUs    = ($VMs | Measure-Object -Property NumCpu -Sum).Sum
    $totalMemGB    = ($VMs | Measure-Object -Property MemoryGB -Sum).Sum
    $totalStorageGB = 0
    foreach ($vm in $VMs) {
        foreach ($d in $vm.Disks) { $totalStorageGB += $d.CapacityGB }
    }
    $totalStorageTB = [math]::Round($totalStorageGB / 1024, 2)

    # Usable capacity per node after HA reservation
    $usableMultiplier    = (100 - $ReservedPercent) / 100
    $usableCoresPerNode  = [math]::Floor($nodeSpec.Cores * $usableMultiplier)
    $usableMemPerNode    = [math]::Floor($nodeSpec.MemoryGB * $usableMultiplier)
    $usableStoragePerNode = [math]::Round($nodeSpec.StorageTB * $usableMultiplier, 2)

    # Nodes needed per resource dimension (minimum 3 for an AVS cluster)
    $nodesByCPU     = [math]::Max(3, [math]::Ceiling($totalvCPUs / $usableCoresPerNode))
    $nodesByMemory  = [math]::Max(3, [math]::Ceiling($totalMemGB / $usableMemPerNode))
    $nodesByStorage = [math]::Max(3, [math]::Ceiling($totalStorageTB / $usableStoragePerNode))
    $nodesRequired  = [math]::Max($nodesByCPU, [math]::Max($nodesByMemory, $nodesByStorage))

    return [ordered]@{
        NodeSKU               = $SKU
        NodeDescription       = $nodeSpec.Description
        NodeSpecs             = $nodeSpec
        ReservedCapacityPct   = $ReservedPercent
        WorkloadDemand        = [ordered]@{
            TotalvCPUs    = $totalvCPUs
            TotalMemoryGB = $totalMemGB
            TotalStorageTB = $totalStorageTB
        }
        UsablePerNode         = [ordered]@{
            Cores     = $usableCoresPerNode
            MemoryGB  = $usableMemPerNode
            StorageTB = $usableStoragePerNode
        }
        NodesRequired         = [ordered]@{
            ByCPU     = $nodesByCPU
            ByMemory  = $nodesByMemory
            ByStorage = $nodesByStorage
            Total     = $nodesRequired
        }
        ClusterConfiguration  = [ordered]@{
            MinimumNodes     = 3
            MaximumNodes     = 16
            RecommendedNodes = $nodesRequired
            HostsPerCluster  = [math]::Min($nodesRequired, 16)
            ClustersNeeded   = [math]::Ceiling($nodesRequired / 16)
        }
    }
}

function Get-AVSNodeSizing {
    <#
    .SYNOPSIS
        Calculates AVS node sizing from the vcenter-inventory.json totals.
        Reads aggregate vCPU, memory, and storage from the VM inventory and
        recommends the minimum node count for each supported AVS SKU.

    .DESCRIPTION
        Uses the per-VM CPU, memory, and provisioned storage values to compute
        aggregate workload demand. For each AVS SKU (AV36, AV36P, AV52) it
        determines the nodes required per resource dimension after applying
        the HA reserve percentage. The AVS minimum cluster size is 3 nodes.

    .PARAMETER VMs
        Array of VM objects from vcenter-inventory.json, each with numCPU,
        memorySizeMB, and provisionedSpaceGB properties.

    .PARAMETER ReservedPercent
        Percentage of node capacity reserved for HA failover (default 25).

    .OUTPUTS
        Ordered hashtable with per-SKU sizing results and a recommendation.

    .EXAMPLE
        $inventory = Get-Content .\vcenter-inventory.json | ConvertFrom-Json
        Get-AVSNodeSizing -VMs $inventory.virtualMachines
    #>
    param(
        [Parameter(Mandatory = $true)]
        [array]$VMs,

        [ValidateRange(0, 50)]
        [int]$ReservedPercent = 25
    )

    $totalvCPUs     = ($VMs | Measure-Object -Property numCPU -Sum).Sum
    $totalMemGB     = [math]::Round(($VMs | Measure-Object -Property memorySizeMB -Sum).Sum / 1024, 2)
    $totalStorageGB = ($VMs | Measure-Object -Property provisionedSpaceGB -Sum).Sum
    $totalStorageTB = [math]::Round($totalStorageGB / 1024, 2)

    $usableMultiplier = (100 - $ReservedPercent) / 100
    $skus = @("AV36", "AV36P", "AV52")
    $perSKU = [ordered]@{}

    foreach ($sku in $skus) {
        $spec = Get-AVSNodeSpec -SKU $sku
        $usableCores   = [math]::Floor($spec.Cores * $usableMultiplier)
        $usableMemGB   = [math]::Floor($spec.MemoryGB * $usableMultiplier)
        $usableStorTB  = [math]::Round($spec.StorageTB * $usableMultiplier, 2)

        $nodesByCPU     = [math]::Max(3, [math]::Ceiling($totalvCPUs / $usableCores))
        $nodesByMemory  = [math]::Max(3, [math]::Ceiling($totalMemGB / $usableMemGB))
        $nodesByStorage = [math]::Max(3, [math]::Ceiling($totalStorageTB / $usableStorTB))
        $nodesRequired  = [math]::Max($nodesByCPU, [math]::Max($nodesByMemory, $nodesByStorage))

        $perSKU[$sku] = [ordered]@{
            SKU              = $sku
            Description      = $spec.Description
            NodesRequired    = $nodesRequired
            NodesByCPU       = $nodesByCPU
            NodesByMemory    = $nodesByMemory
            NodesByStorage   = $nodesByStorage
            UsableCoresNode  = $usableCores
            UsableMemGBNode  = $usableMemGB
            UsableStorTBNode = $usableStorTB
        }
    }

    # Recommend the cheapest SKU that meets demand at the minimum node count
    $recommended = $skus | Sort-Object { $perSKU[$_].NodesRequired } | Select-Object -First 1

    return [ordered]@{
        WorkloadTotals = [ordered]@{
            TotalvCPUs      = $totalvCPUs
            TotalMemoryGB   = $totalMemGB
            TotalStorageTB  = $totalStorageTB
            TotalStorageGB  = $totalStorageGB
            VMCount         = $VMs.Count
        }
        HAReservePercent  = $ReservedPercent
        PerSKU            = $perSKU
        Recommendation    = [ordered]@{
            SKU           = $recommended
            NodesRequired = $perSKU[$recommended].NodesRequired
            Rationale     = "Minimum node count ($($perSKU[$recommended].NodesRequired)) meets workload demand of $totalvCPUs vCPUs, $totalMemGB GB RAM, $totalStorageTB TB storage with $ReservedPercent% HA reserve."
        }
    }
}

function Test-NSXCompatibility {
    <#
    .SYNOPSIS
        Evaluates NSX-V to NSX-T migration considerations.
        AVS uses NSX-T; environments running NSX-V require network migration planning.
    #>
    param([hashtable]$NetworkTopology)

    $result = @{
        Check    = "NSX Compatibility (NSX-V to NSX-T)"
        Status   = "Warn"
        Details  = "AVS runs NSX-T. Source environments on NSX-V require network migration planning."
        Findings = @()
        Recommendations = @()
    }

    if ($NetworkTopology.NSXVersion -and $NetworkTopology.NSXVersion -match "^6\.") {
        $result.Findings += "Source environment runs NSX-V $($NetworkTopology.NSXVersion)."
        $result.Findings += "NSX-V is end-of-life; migration to NSX-T (used in AVS) is required."
        $result.Recommendations += "Plan NSX-V to NSX-T segment mapping as part of HCX network extension."
        $result.Recommendations += "Use HCX Network Extension to stretch L2 segments during migration."
        $result.Recommendations += "After migration cutover, remove HCX L2 extension and use NSX-T native segments."
    }

    if ($NetworkTopology.LogicalSwitches) {
        $result.Findings += "$($NetworkTopology.LogicalSwitches.Count) logical switch(es) need to be mapped to NSX-T segments."
        foreach ($ls in $NetworkTopology.LogicalSwitches) {
            $result.Findings += "  - $($ls.Name) ($($ls.Subnet)) -> AVS NSX-T segment required"
        }
    }

    if ($NetworkTopology.DistributedSwitches) {
        foreach ($vds in $NetworkTopology.DistributedSwitches) {
            $result.Findings += "VDS '$($vds.Name)' with $($vds.PortGroups.Count) port group(s) — verify MTU ($($vds.MTU)) matches AVS config."
        }
    }

    return $result
}

function Test-DRSRuleCompatibility {
    <#
    .SYNOPSIS
        Checks whether DRS affinity/anti-affinity rules can be replicated in AVS.
    #>
    param([array]$DRSRules)

    $result = @{
        Check    = "DRS Rule Compatibility"
        Status   = "Pass"
        Details  = "AVS supports DRS rules. Existing rules should be recreated in the AVS cluster."
        Findings = @()
        Rules    = @()
    }

    if (-not $DRSRules -or $DRSRules.Count -eq 0) {
        $result.Findings += "No DRS rules found."
        return $result
    }

    foreach ($rule in $DRSRules) {
        $ruleResult = @{
            Name    = $rule.Name
            Type    = $rule.Type
            Enabled = $rule.Enabled
            VMs     = $rule.VMs
            Status  = "Pass"
            Message = "Rule can be recreated in AVS."
        }
        $result.Rules += $ruleResult
        $result.Findings += "DRS rule '$($rule.Name)' ($($rule.Type)) — recreate in AVS cluster."
    }

    $result.Status = "Warn"
    $result.Findings += "Total $($DRSRules.Count) DRS rule(s) must be manually recreated in AVS."
    return $result
}

# ---------------------------------------------------------------------------
# Load or generate inventory
# ---------------------------------------------------------------------------

function Get-InventoryData {
    if ($Simulate) {
        Write-Log "Generating simulated inventory for assessment..."
        # Re-use the export-inventory simulation functions inline
        $scriptDir = Split-Path -Parent $MyInvocation.ScriptName
        $exportScript = Join-Path $scriptDir "export-inventory.ps1"

        if (Test-Path $exportScript) {
            Write-Log "Running export-inventory.ps1 -Simulate to generate inventory..."
            & $exportScript -VCenterServer "vcenter.harbor.local" -Simulate -OutputPath $OutputPath -IncludePerformanceMetrics
            $inventoryFile = Join-Path $OutputPath "vcenter-inventory-export.json"
            if (Test-Path $inventoryFile) {
                return (Get-Content $inventoryFile -Raw | ConvertFrom-Json -AsHashtable)
            }
        }

        Write-Log "Export script not available — using inline simulated data" -Level WARN
        throw "Run export-inventory.ps1 -Simulate first to generate inventory data."
    }
    else {
        $path = if ($InventoryPath) { $InventoryPath } else { Join-Path $OutputPath "vcenter-inventory-export.json" }
        if (-not (Test-Path $path)) {
            throw "Inventory file not found at '$path'. Run export-inventory.ps1 first."
        }
        Write-Log "Loading inventory from $path"
        return (Get-Content $path -Raw | ConvertFrom-Json -AsHashtable)
    }
}

# ---------------------------------------------------------------------------
# Readiness scoring
# ---------------------------------------------------------------------------

function Get-ReadinessScore {
    <#
    .SYNOPSIS
        Calculates an overall readiness percentage from individual check results.
        Pass = 100, Warn = 70, Fail = 0, weighted equally.
    #>
    param([array]$Checks)

    $weights = @{ "Pass" = 100; "Warn" = 70; "Fail" = 0 }
    $totalScore = 0
    foreach ($check in $Checks) {
        $totalScore += $weights[$check.Status]
    }
    $score = [math]::Round($totalScore / @($Checks).Count, 1)

    $readiness = if ($score -ge 90) { "Ready" }
                 elseif ($score -ge 70) { "Ready with Remediation" }
                 elseif ($score -ge 50) { "Significant Remediation Required" }
                 else { "Not Ready" }

    return @{
        Score      = $score
        MaxScore   = 100
        Readiness  = $readiness
        PassCount  = @($Checks | Where-Object { $_.Status -eq "Pass" }).Count
        WarnCount  = @($Checks | Where-Object { $_.Status -eq "Warn" }).Count
        FailCount  = @($Checks | Where-Object { $_.Status -eq "Fail" }).Count
        TotalChecks = @($Checks).Count
    }
}

# ---------------------------------------------------------------------------
# Main execution
# ---------------------------------------------------------------------------

try {
    Write-Log "============================================="
    Write-Log "  Harbor Retail AVS Compatibility Assessment"
    Write-Log "============================================="
    Write-Log "AVS Node SKU        : $AVSNodeSKU"
    Write-Log "HA Reserve          : $ReservedCapacityPercent%"
    Write-Log "Mode                : $(if ($Simulate) { 'SIMULATION' } else { 'INVENTORY FILE' })"
    Write-Log ""

    if (-not (Test-Path $OutputPath)) {
        New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
    }

    # Load inventory
    Write-ProgressStep -Activity "Compatibility Assessment" -Status "Loading inventory..." -PercentComplete 5
    $inventory = Get-InventoryData
    $vms = $inventory.VirtualMachines
    Write-Log "Loaded $($vms.Count) VMs for assessment" -Level SUCCESS

    # Run compatibility checks
    $checks = [System.Collections.Generic.List[hashtable]]::new()

    Write-ProgressStep -Activity "Compatibility Assessment" -Status "Checking vSphere version..." -PercentComplete 15
    Write-Log "Checking vSphere version compatibility..."
    $checks.Add((Test-VSphereVersion -Inventory $inventory))

    Write-ProgressStep -Activity "Compatibility Assessment" -Status "Checking hardware versions..." -PercentComplete 25
    Write-Log "Checking VM hardware versions..."
    $checks.Add((Test-VMHardwareVersions -VMs $vms))

    Write-ProgressStep -Activity "Compatibility Assessment" -Status "Checking VMware Tools..." -PercentComplete 35
    Write-Log "Checking VMware Tools status..."
    $checks.Add((Test-VMwareTools -VMs $vms))

    Write-ProgressStep -Activity "Compatibility Assessment" -Status "Checking snapshots..." -PercentComplete 45
    Write-Log "Checking for snapshots..."
    $checks.Add((Test-Snapshots -VMs $vms))

    Write-ProgressStep -Activity "Compatibility Assessment" -Status "Checking network adapters..." -PercentComplete 55
    Write-Log "Checking network adapter compatibility..."
    $checks.Add((Test-NetworkAdapters -VMs $vms))

    Write-ProgressStep -Activity "Compatibility Assessment" -Status "Checking disk configuration..." -PercentComplete 65
    Write-Log "Checking disk configurations..."
    $checks.Add((Test-DiskConfiguration -VMs $vms))

    Write-ProgressStep -Activity "Compatibility Assessment" -Status "Checking NSX compatibility..." -PercentComplete 75
    Write-Log "Checking NSX-V to NSX-T compatibility..."
    $checks.Add((Test-NSXCompatibility -NetworkTopology $inventory.NetworkTopology))

    Write-ProgressStep -Activity "Compatibility Assessment" -Status "Checking DRS rules..." -PercentComplete 82
    Write-Log "Checking DRS rule compatibility..."
    $checks.Add((Test-DRSRuleCompatibility -DRSRules $inventory.DRSRules))

    # AVS capacity planning
    Write-ProgressStep -Activity "Compatibility Assessment" -Status "Calculating AVS capacity..." -PercentComplete 90
    Write-Log "Calculating AVS capacity requirements..."
    $capacityPlan = Get-AVSCapacityRequirements -VMs $vms -SKU $AVSNodeSKU -ReservedPercent $ReservedCapacityPercent

    # Readiness score
    Write-ProgressStep -Activity "Compatibility Assessment" -Status "Computing readiness score..." -PercentComplete 95
    $readiness = Get-ReadinessScore -Checks $checks

    # Build the per-VM summary
    $vmSummary = foreach ($vm in $vms) {
        $vmChecks = @()
        foreach ($check in $checks) {
            if ($check.ContainsKey('VMResults') -and $check.VMResults) {
                $vmCheck = @($check.VMResults | Where-Object { $_['VMName'] -eq $vm.Name })
                if ($vmCheck.Count -gt 0) {
                    $vmChecks += @{
                        Check   = $check['Check']
                        Status  = $vmCheck[0]['Status']
                        Message = $vmCheck[0]['Message']
                    }
                }
            }
        }

        $overallStatus = "Pass"
        if ($vmChecks | Where-Object { $_.Status -eq "Fail" }) { $overallStatus = "Fail" }
        elseif ($vmChecks | Where-Object { $_.Status -eq "Warn" }) { $overallStatus = "Warn" }

        [ordered]@{
            VMName        = $vm.Name
            OverallStatus = $overallStatus
            Tier          = if ($vm.ResourcePool -match "Web") { "Web" } elseif ($vm.ResourcePool -match "App") { "App" } else { "DB" }
            vCPUs         = $vm.NumCpu
            MemoryGB      = $vm.MemoryGB
            StorageGB     = ($vm.Disks | ForEach-Object { $_.CapacityGB } | Measure-Object -Sum).Sum
            Checks        = $vmChecks
        }
    }

    # Remediation recommendations
    $remediations = [System.Collections.ArrayList]::new()
    foreach ($check in $checks) {
        if ($check.Status -eq "Fail" -or $check.Status -eq "Warn") {
            $remediation = @{
                Check     = $check.Check
                Severity  = $check.Status
                Action    = ""
            }
            switch -Wildcard ($check.Check) {
                "*Hardware*"  { $remediation.Action = "Upgrade VM hardware version to vmx-19 or later using vCenter." }
                "*Tools*"     { $remediation.Action = "Install or upgrade VMware Tools on affected VMs." }
                "*Snapshot*"  { $remediation.Action = "Delete or consolidate all snapshots before migration." }
                "*Network*"   { $remediation.Action = "Upgrade E1000/E1000E NICs to VMXNET3." }
                "*Disk*"      { $remediation.Action = "Resize disks exceeding vSAN limits." }
                "*NSX*"       { $remediation.Action = "Map NSX-V logical switches to AVS NSX-T segments. Use HCX L2 extension during migration." }
                "*DRS*"       { $remediation.Action = "Document existing DRS rules and recreate them in the AVS vCenter after migration." }
                "*vSphere*"   { $remediation.Action = "Upgrade source vSphere to 6.7+ for best HCX compatibility." }
                default       { $remediation.Action = "Review findings and address accordingly." }
            }
            [void]$remediations.Add($remediation)
        }
    }

    # Assemble final report
    $duration = (Get-Date) - $script:StartTime

    $report = [ordered]@{
        ReportMetadata     = [ordered]@{
            ReportDate       = (Get-Date).ToString("o")
            ScriptVersion    = "1.0.0"
            Mode             = if ($Simulate) { "Simulation" } else { "Inventory File" }
            SourceVCenter    = $inventory.ExportMetadata.VCenterServer
            Duration         = "$([math]::Round($duration.TotalSeconds, 1))s"
        }
        ReadinessScore     = $readiness
        CompatibilityChecks = $checks
        VMCompatibilitySummary = $vmSummary
        AVSCapacityPlan    = $capacityPlan
        Remediations       = $remediations
        MigrationReadiness = [ordered]@{
            ReadyVMs        = @($vmSummary | Where-Object { $_.OverallStatus -eq "Pass" }).Count
            RemediationVMs  = @($vmSummary | Where-Object { $_.OverallStatus -eq "Warn" }).Count
            BlockedVMs      = @($vmSummary | Where-Object { $_.OverallStatus -eq "Fail" }).Count
        }
    }

    # Write report
    $reportPath = Join-Path $OutputPath "compatibility-report.json"
    $report | ConvertTo-Json -Depth 15 | Set-Content -Path $reportPath -Encoding UTF8
    Write-Log "Compatibility report: $reportPath" -Level SUCCESS

    Write-Progress -Activity "Compatibility Assessment" -Completed

    # ---- Console summary ----
    Write-Log ""
    Write-Log "============================================="
    Write-Log "  Assessment Results"
    Write-Log "============================================="
    Write-Log "Readiness Score     : $($readiness.Score)% — $($readiness.Readiness)"
    Write-Log "Checks Passed       : $($readiness.PassCount) / $($readiness.TotalChecks)"
    Write-Log "Warnings            : $($readiness.WarnCount)"
    Write-Log "Failures            : $($readiness.FailCount)"
    Write-Log ""
    Write-Log "--- Per-VM Summary ---"
    foreach ($vm in $vmSummary) {
        $icon = switch ($vm.OverallStatus) { "Pass" { "[PASS]" }; "Warn" { "[WARN]" }; "Fail" { "[FAIL]" } }
        $color = switch ($vm.OverallStatus) { "Pass" { "SUCCESS" }; "Warn" { "WARN" }; "Fail" { "ERROR" } }
        Write-Log "  $icon $($vm.VMName) ($($vm.Tier) tier) — $($vm.vCPUs) vCPU, $($vm.MemoryGB) GB RAM, $($vm.StorageGB) GB disk" -Level $color
    }
    Write-Log ""
    Write-Log "--- AVS Capacity Plan ($AVSNodeSKU) ---"
    Write-Log "  Workload: $($capacityPlan.WorkloadDemand.TotalvCPUs) vCPUs, $($capacityPlan.WorkloadDemand.TotalMemoryGB) GB RAM, $($capacityPlan.WorkloadDemand.TotalStorageTB) TB storage"
    Write-Log "  Nodes required: $($capacityPlan.NodesRequired.Total) (CPU: $($capacityPlan.NodesRequired.ByCPU), Mem: $($capacityPlan.NodesRequired.ByMemory), Storage: $($capacityPlan.NodesRequired.ByStorage))"
    Write-Log "  Cluster config: $($capacityPlan.ClusterConfiguration.ClustersNeeded) cluster(s) x $($capacityPlan.ClusterConfiguration.HostsPerCluster) hosts"
    Write-Log ""

    if ($remediations.Count -gt 0) {
        Write-Log "--- Remediations Required ---" -Level WARN
        foreach ($r in $remediations) {
            Write-Log "  [$($r.Severity)] $($r.Check): $($r.Action)" -Level WARN
        }
    }
    else {
        Write-Log "No remediations required — environment is ready for migration!" -Level SUCCESS
    }

    Write-Log ""
    Write-Log "Report written to: $reportPath" -Level SUCCESS
}
catch {
    Write-Log "FATAL: $($_.Exception.Message)" -Level ERROR
    Write-Log "Stack: $($_.ScriptStackTrace)" -Level ERROR
    exit 1
}
