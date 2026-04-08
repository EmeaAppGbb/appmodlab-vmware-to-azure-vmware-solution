<#
.SYNOPSIS
    Exports a comprehensive VMware vCenter inventory for Azure VMware Solution (AVS) migration planning.

.DESCRIPTION
    Connects to a vCenter Server and exports detailed inventory data including:
    - Virtual Machine specifications (CPU, memory, storage, network)
    - Network topology (distributed switches, port groups, logical switches)
    - Resource pool configurations and reservations
    - DRS rules (affinity/anti-affinity)
    - HA cluster configuration
    - VMware Tools status and VM hardware versions

    When run with -Simulate, uses Harbor Retail sample data from the repository
    config files instead of connecting to a live vCenter.

    Output is written as structured JSON for consumption by assess-compatibility.ps1
    and migration-runbook.ps1.

.PARAMETER VCenterServer
    FQDN or IP address of the vCenter Server to connect to.

.PARAMETER Credential
    PSCredential object for vCenter authentication. If omitted, you will be prompted.

.PARAMETER OutputPath
    Directory where JSON report files are written. Defaults to .\output.

.PARAMETER Simulate
    When specified, generates inventory from built-in Harbor Retail sample data
    instead of connecting to a live vCenter. Use for demos and testing.

.PARAMETER IncludePerformanceMetrics
    When specified, collects 30-day performance statistics for each VM.
    This increases execution time significantly on large environments.

.PARAMETER Datacenter
    Limit export to a specific datacenter name. If omitted, all datacenters are exported.

.EXAMPLE
    .\export-inventory.ps1 -VCenterServer vcenter.harbor.local -Simulate
    Generates a full inventory export using simulated Harbor Retail data.

.EXAMPLE
    .\export-inventory.ps1 -VCenterServer vcenter.harbor.local -Credential (Get-Credential) -OutputPath C:\reports
    Connects to a live vCenter and exports inventory to C:\reports.

.EXAMPLE
    .\export-inventory.ps1 -VCenterServer vcenter.harbor.local -Simulate -IncludePerformanceMetrics
    Generates inventory with 30-day performance baselines included.

.NOTES
    Author  : Harbor Retail Platform Engineering
    Requires: PowerShell 5.1+, VMware PowerCLI 13.0+ (live mode only)
    Version : 1.0.0
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, HelpMessage = "vCenter Server FQDN or IP address")]
    [ValidateNotNullOrEmpty()]
    [string]$VCenterServer,

    [Parameter(Mandatory = $false, HelpMessage = "PSCredential for vCenter authentication")]
    [PSCredential]$Credential,

    [Parameter(Mandatory = $false, HelpMessage = "Output directory for JSON reports")]
    [ValidateNotNullOrEmpty()]
    [string]$OutputPath = ".\output",

    [Parameter(Mandatory = $false, HelpMessage = "Use simulated Harbor Retail data")]
    [switch]$Simulate,

    [Parameter(Mandatory = $false, HelpMessage = "Include 30-day performance metrics")]
    [switch]$IncludePerformanceMetrics,

    [Parameter(Mandatory = $false, HelpMessage = "Limit to a specific datacenter")]
    [string]$Datacenter
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$script:StartTime = Get-Date

# ---------------------------------------------------------------------------
# Helper functions
# ---------------------------------------------------------------------------

function Write-Log {
    <#
    .SYNOPSIS
        Writes a timestamped message to the console with colour coding.
    #>
    param(
        [string]$Message,
        [ValidateSet("INFO", "WARN", "ERROR", "SUCCESS")]
        [string]$Level = "INFO"
    )
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $colors = @{ INFO = "Cyan"; WARN = "Yellow"; ERROR = "Red"; SUCCESS = "Green" }
    Write-Host "[$timestamp] [$Level] $Message" -ForegroundColor $colors[$Level]
}

function Write-ProgressStep {
    <#
    .SYNOPSIS
        Updates the PowerShell progress bar for the current export phase.
    #>
    param(
        [string]$Activity,
        [string]$Status,
        [int]$PercentComplete
    )
    Write-Progress -Activity $Activity -Status $Status -PercentComplete $PercentComplete
}

function New-OutputDirectory {
    if (-not (Test-Path $OutputPath)) {
        New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
        Write-Log "Created output directory: $OutputPath"
    }
}

# ---------------------------------------------------------------------------
# Simulated data builders — mirror the Harbor Retail lab environment
# ---------------------------------------------------------------------------

function Get-SimulatedVMInventory {
    <#
    .SYNOPSIS
        Returns an array of VM objects matching the Harbor Retail vCenter inventory.
    #>
    $vms = @(
        @{
            Name              = "HARBOR-WEB01"
            GuestOS           = "Windows Server 2019 Standard"
            GuestOSVersion    = "10.0.17763"
            PowerState        = "PoweredOn"
            NumCpu            = 4
            CoresPerSocket    = 2
            NumSockets        = 2
            MemoryGB          = 8
            HardwareVersion   = "vmx-19"
            VMToolsVersion    = "12.1.5"
            VMToolsStatus     = "toolsOk"
            Domain            = "harbor.local"
            Folder            = "Harbor-Retail/Web-Tier"
            ResourcePool      = "Web-Pool"
            Cluster           = "Harbor-Production"
            Host              = "esxi-01.harbor.local"
            Disks             = @(
                @{
                    Label         = "Hard disk 1"
                    CapacityGB    = 100
                    UsedGB        = 45
                    StorageFormat = "Thin"
                    Datastore     = "vsanDatastore"
                }
            )
            NetworkAdapters   = @(
                @{
                    Name         = "Network adapter 1"
                    Type         = "Vmxnet3"
                    NetworkName  = "VLAN-Web-10"
                    MacAddress   = "00:50:56:a1:01:01"
                    IPAddress    = "10.10.10.11"
                    SubnetMask   = "255.255.255.0"
                    Gateway      = "10.10.10.1"
                    DNS          = @("10.10.1.10", "10.10.1.11")
                    Connected    = $true
                }
            )
            Snapshots         = @()
            Tags              = @("Production", "Web", "Harbor-Retail")
            Criticality       = "High"
            BackupPolicy      = "daily"
            Notes             = "IIS 10.0 - HarborRetailWeb - .NET 4.8"
            Software          = @(
                @{ Name = "IIS"; Version = "10.0"; Bindings = @("HTTPS:443", "HTTP:80") }
                @{ Name = ".NET Framework"; Version = "4.8" }
            )
            FirewallRules     = @(
                @{ Name = "HTTP"; Port = 80; Protocol = "TCP"; Direction = "Inbound" }
                @{ Name = "HTTPS"; Port = 443; Protocol = "TCP"; Direction = "Inbound" }
                @{ Name = "RDP"; Port = 3389; Protocol = "TCP"; Direction = "Inbound"; Restricted = $true }
            )
        },
        @{
            Name              = "HARBOR-WEB02"
            GuestOS           = "Windows Server 2019 Standard"
            GuestOSVersion    = "10.0.17763"
            PowerState        = "PoweredOn"
            NumCpu            = 4
            CoresPerSocket    = 2
            NumSockets        = 2
            MemoryGB          = 8
            HardwareVersion   = "vmx-19"
            VMToolsVersion    = "12.1.5"
            VMToolsStatus     = "toolsOk"
            Domain            = "harbor.local"
            Folder            = "Harbor-Retail/Web-Tier"
            ResourcePool      = "Web-Pool"
            Cluster           = "Harbor-Production"
            Host              = "esxi-02.harbor.local"
            Disks             = @(
                @{
                    Label         = "Hard disk 1"
                    CapacityGB    = 100
                    UsedGB        = 42
                    StorageFormat = "Thin"
                    Datastore     = "vsanDatastore"
                }
            )
            NetworkAdapters   = @(
                @{
                    Name         = "Network adapter 1"
                    Type         = "Vmxnet3"
                    NetworkName  = "VLAN-Web-10"
                    MacAddress   = "00:50:56:a1:01:02"
                    IPAddress    = "10.10.10.12"
                    SubnetMask   = "255.255.255.0"
                    Gateway      = "10.10.10.1"
                    DNS          = @("10.10.1.10", "10.10.1.11")
                    Connected    = $true
                }
            )
            Snapshots         = @()
            Tags              = @("Production", "Web", "Harbor-Retail")
            Criticality       = "High"
            BackupPolicy      = "daily"
            Notes             = "IIS 10.0 - HarborRetailWeb - .NET 4.8"
            Software          = @(
                @{ Name = "IIS"; Version = "10.0"; Bindings = @("HTTPS:443", "HTTP:80") }
                @{ Name = ".NET Framework"; Version = "4.8" }
            )
            FirewallRules     = @(
                @{ Name = "HTTP"; Port = 80; Protocol = "TCP"; Direction = "Inbound" }
                @{ Name = "HTTPS"; Port = 443; Protocol = "TCP"; Direction = "Inbound" }
                @{ Name = "RDP"; Port = 3389; Protocol = "TCP"; Direction = "Inbound"; Restricted = $true }
            )
        },
        @{
            Name              = "HARBOR-APP01"
            GuestOS           = "Windows Server 2019 Standard"
            GuestOSVersion    = "10.0.17763"
            PowerState        = "PoweredOn"
            NumCpu            = 8
            CoresPerSocket    = 4
            NumSockets        = 2
            MemoryGB          = 16
            HardwareVersion   = "vmx-19"
            VMToolsVersion    = "12.1.5"
            VMToolsStatus     = "toolsOk"
            Domain            = "harbor.local"
            Folder            = "Harbor-Retail/App-Tier"
            ResourcePool      = "App-Pool"
            Cluster           = "Harbor-Production"
            Host              = "esxi-01.harbor.local"
            Disks             = @(
                @{
                    Label         = "Hard disk 1"
                    CapacityGB    = 200
                    UsedGB        = 95
                    StorageFormat = "Thin"
                    Datastore     = "vsanDatastore"
                }
            )
            NetworkAdapters   = @(
                @{
                    Name         = "Network adapter 1"
                    Type         = "Vmxnet3"
                    NetworkName  = "VLAN-App-20"
                    MacAddress   = "00:50:56:a1:02:01"
                    IPAddress    = "10.10.20.11"
                    SubnetMask   = "255.255.255.0"
                    Gateway      = "10.10.20.1"
                    DNS          = @("10.10.1.10", "10.10.1.11")
                    Connected    = $true
                }
            )
            Snapshots         = @()
            Tags              = @("Production", "App", "Harbor-Retail")
            Criticality       = "High"
            BackupPolicy      = "daily"
            Notes             = "Harbor Retail API Server v3.5.2 - .NET 4.8 - Java 11.0.18"
            Software          = @(
                @{ Name = "Harbor Retail API"; Version = "3.5.2"; Endpoints = @("/api/v2/inventory", "/api/v2/orders", "/api/v2/customers") }
                @{ Name = ".NET Framework"; Version = "4.8" }
                @{ Name = "Java Runtime"; Version = "11.0.18" }
            )
            FirewallRules     = @(
                @{ Name = "API HTTPS"; Port = 8443; Protocol = "TCP"; Direction = "Inbound" }
                @{ Name = "API HTTP"; Port = 8080; Protocol = "TCP"; Direction = "Inbound" }
                @{ Name = "SQL Client"; Port = 1433; Protocol = "TCP"; Direction = "Outbound" }
                @{ Name = "RDP"; Port = 3389; Protocol = "TCP"; Direction = "Inbound"; Restricted = $true }
            )
        },
        @{
            Name              = "HARBOR-APP02"
            GuestOS           = "Windows Server 2019 Standard"
            GuestOSVersion    = "10.0.17763"
            PowerState        = "PoweredOn"
            NumCpu            = 8
            CoresPerSocket    = 4
            NumSockets        = 2
            MemoryGB          = 16
            HardwareVersion   = "vmx-19"
            VMToolsVersion    = "12.1.5"
            VMToolsStatus     = "toolsOk"
            Domain            = "harbor.local"
            Folder            = "Harbor-Retail/App-Tier"
            ResourcePool      = "App-Pool"
            Cluster           = "Harbor-Production"
            Host              = "esxi-02.harbor.local"
            Disks             = @(
                @{
                    Label         = "Hard disk 1"
                    CapacityGB    = 200
                    UsedGB        = 89
                    StorageFormat = "Thin"
                    Datastore     = "vsanDatastore"
                }
            )
            NetworkAdapters   = @(
                @{
                    Name         = "Network adapter 1"
                    Type         = "Vmxnet3"
                    NetworkName  = "VLAN-App-20"
                    MacAddress   = "00:50:56:a1:02:02"
                    IPAddress    = "10.10.20.12"
                    SubnetMask   = "255.255.255.0"
                    Gateway      = "10.10.20.1"
                    DNS          = @("10.10.1.10", "10.10.1.11")
                    Connected    = $true
                }
            )
            Snapshots         = @()
            Tags              = @("Production", "App", "Harbor-Retail")
            Criticality       = "High"
            BackupPolicy      = "daily"
            Notes             = "Harbor Retail API Server v3.5.2 - .NET 4.8 - Java 11.0.18"
            Software          = @(
                @{ Name = "Harbor Retail API"; Version = "3.5.2"; Endpoints = @("/api/v2/inventory", "/api/v2/orders", "/api/v2/customers") }
                @{ Name = ".NET Framework"; Version = "4.8" }
                @{ Name = "Java Runtime"; Version = "11.0.18" }
            )
            FirewallRules     = @(
                @{ Name = "API HTTPS"; Port = 8443; Protocol = "TCP"; Direction = "Inbound" }
                @{ Name = "API HTTP"; Port = 8080; Protocol = "TCP"; Direction = "Inbound" }
                @{ Name = "SQL Client"; Port = 1433; Protocol = "TCP"; Direction = "Outbound" }
                @{ Name = "RDP"; Port = 3389; Protocol = "TCP"; Direction = "Inbound"; Restricted = $true }
            )
        },
        @{
            Name              = "HARBOR-DB01"
            GuestOS           = "Windows Server 2019 Standard"
            GuestOSVersion    = "10.0.17763"
            PowerState        = "PoweredOn"
            NumCpu            = 16
            CoresPerSocket    = 8
            NumSockets        = 2
            MemoryGB          = 64
            HardwareVersion   = "vmx-19"
            VMToolsVersion    = "12.1.5"
            VMToolsStatus     = "toolsOk"
            Domain            = "harbor.local"
            Folder            = "Harbor-Retail/DB-Tier"
            ResourcePool      = "DB-Pool"
            Cluster           = "Harbor-Production"
            Host              = "esxi-03.harbor.local"
            Disks             = @(
                @{
                    Label         = "Hard disk 1"
                    CapacityGB    = 200
                    UsedGB        = 85
                    StorageFormat = "ThickEagerZeroed"
                    Datastore     = "vsanDatastore"
                }
                @{
                    Label         = "Hard disk 2"
                    CapacityGB    = 500
                    UsedGB        = 290
                    StorageFormat = "ThickEagerZeroed"
                    Datastore     = "vsanDatastore-SSD"
                }
            )
            NetworkAdapters   = @(
                @{
                    Name         = "Network adapter 1"
                    Type         = "Vmxnet3"
                    NetworkName  = "VLAN-DB-30"
                    MacAddress   = "00:50:56:a1:03:01"
                    IPAddress    = "10.10.30.11"
                    SubnetMask   = "255.255.255.0"
                    Gateway      = "10.10.30.1"
                    DNS          = @("10.10.1.10", "10.10.1.11")
                    Connected    = $true
                }
            )
            Snapshots         = @()
            Tags              = @("Production", "Database", "Harbor-Retail")
            Criticality       = "Critical"
            BackupPolicy      = "full-daily-log-15min"
            Notes             = "SQL Server 2019 Enterprise v15.0.4316.3"
            Software          = @(
                @{
                    Name       = "SQL Server 2019 Enterprise"
                    Version    = "15.0.4316.3"
                    MaxMemory  = 51200
                    MinMemory  = 8192
                    MaxDOP     = 8
                    Collation  = "SQL_Latin1_General_CP1_CI_AS"
                    Databases  = @(
                        @{ Name = "HarborRetail"; SizeGB = 85; RecoveryModel = "Full"; CompatLevel = 150 }
                        @{ Name = "HarborRetail_Archive"; SizeGB = 120; RecoveryModel = "Simple"; CompatLevel = 150 }
                        @{ Name = "HarborRetail_Staging"; SizeGB = 15; RecoveryModel = "Simple"; CompatLevel = 150 }
                    )
                }
            )
            FirewallRules     = @(
                @{ Name = "SQL Server"; Port = 1433; Protocol = "TCP"; Direction = "Inbound" }
                @{ Name = "SQL Browser"; Port = 1434; Protocol = "UDP"; Direction = "Inbound" }
                @{ Name = "Always On"; Port = 5022; Protocol = "TCP"; Direction = "Inbound" }
                @{ Name = "RDP"; Port = 3389; Protocol = "TCP"; Direction = "Inbound"; Restricted = $true }
            )
        }
    )
    return $vms
}

function Get-SimulatedPerformanceMetrics {
    <#
    .SYNOPSIS
        Returns simulated 30-day average performance baselines per VM.
    #>
    $metrics = @{
        "HARBOR-WEB01" = @{
            Period          = "30-day average"
            CpuUsagePercent = 35
            MemUsagePercent = 55
            ReadIOPS        = 120
            WriteIOPS       = 45
            NetworkMbps     = 15
            PacketsPerSec   = $null
        }
        "HARBOR-WEB02" = @{
            Period          = "30-day average"
            CpuUsagePercent = 30
            MemUsagePercent = 50
            ReadIOPS        = 110
            WriteIOPS       = 40
            NetworkMbps     = 12
            PacketsPerSec   = $null
        }
        "HARBOR-APP01" = @{
            Period          = "30-day average"
            CpuUsagePercent = 42
            MemUsagePercent = 62
            ReadIOPS        = 250
            WriteIOPS       = 150
            NetworkMbps     = 25
            PacketsPerSec   = 4500
        }
        "HARBOR-APP02" = @{
            Period          = "30-day average"
            CpuUsagePercent = 38
            MemUsagePercent = 58
            ReadIOPS        = 230
            WriteIOPS       = 135
            NetworkMbps     = 22
            PacketsPerSec   = 4100
        }
        "HARBOR-DB01" = @{
            Period          = "30-day average"
            CpuUsagePercent = 48
            MemUsagePercent = 82
            ReadIOPS        = 1800
            WriteIOPS       = 950
            NetworkMbps     = 45
            PacketsPerSec   = 8500
        }
    }
    return $metrics
}

function Get-SimulatedNetworkTopology {
    return @{
        NSXVersion          = "6.4.10"
        VDSVersion          = "7.0.0"
        DistributedSwitches = @(
            @{
                Name      = "Harbor-VDS-01"
                Version   = "7.0.0"
                MTU       = 1600
                NumPorts  = 512
                Uplinks   = @("Uplink 1", "Uplink 2")
                PortGroups = @(
                    @{ Name = "Web-Segment"; VLAN = 10; ActivePorts = 2 }
                    @{ Name = "App-Segment"; VLAN = 20; ActivePorts = 2 }
                    @{ Name = "DB-Segment";  VLAN = 30; ActivePorts = 1 }
                )
            }
        )
        LogicalSwitches     = @(
            @{ Name = "LS-Web"; VNI = 5001; Subnet = "10.10.10.0/24"; Gateway = "10.10.10.1" }
            @{ Name = "LS-App"; VNI = 5002; Subnet = "10.10.20.0/24"; Gateway = "10.10.20.1" }
            @{ Name = "LS-DB";  VNI = 5003; Subnet = "10.10.30.0/24"; Gateway = "10.10.30.1" }
        )
        DNSRecords          = @(
            @{ Hostname = "web01"; Zone = "harbor.local"; IP = "10.10.10.11"; Type = "A" }
            @{ Hostname = "web02"; Zone = "harbor.local"; IP = "10.10.10.12"; Type = "A" }
            @{ Hostname = "app01"; Zone = "harbor.local"; IP = "10.10.20.11"; Type = "A" }
            @{ Hostname = "app02"; Zone = "harbor.local"; IP = "10.10.20.12"; Type = "A" }
            @{ Hostname = "db01";  Zone = "harbor.local"; IP = "10.10.30.11"; Type = "A" }
            @{ Hostname = "portal"; Zone = "harbor.local"; IP = "192.168.1.100"; Type = "A"; Notes = "Load balancer VIP" }
        )
    }
}

function Get-SimulatedResourcePools {
    return @(
        @{
            Name              = "Web-Pool"
            Cluster           = "Harbor-Production"
            CpuReservationMHz = 4000
            CpuSharesLevel    = "normal"
            MemReservationGB  = 16
            MemSharesLevel    = "normal"
            VMs               = @("HARBOR-WEB01", "HARBOR-WEB02")
        }
        @{
            Name              = "App-Pool"
            Cluster           = "Harbor-Production"
            CpuReservationMHz = 8000
            CpuSharesLevel    = "high"
            MemReservationGB  = 32
            MemSharesLevel    = "high"
            VMs               = @("HARBOR-APP01", "HARBOR-APP02")
        }
        @{
            Name              = "DB-Pool"
            Cluster           = "Harbor-Production"
            CpuReservationMHz = 16000
            CpuSharesLevel    = "high"
            MemReservationGB  = 64
            MemSharesLevel    = "high"
            VMs               = @("HARBOR-DB01")
        }
    )
}

function Get-SimulatedDRSRules {
    return @(
        @{
            Name    = "Web-Tier-Anti-Affinity"
            Type    = "anti-affinity"
            Enabled = $true
            VMs     = @("HARBOR-WEB01", "HARBOR-WEB02")
        }
        @{
            Name    = "App-Tier-Anti-Affinity"
            Type    = "anti-affinity"
            Enabled = $true
            VMs     = @("HARBOR-APP01", "HARBOR-APP02")
        }
    )
}

function Get-SimulatedHAConfig {
    return @{
        ClusterName           = "Harbor-Production"
        HAEnabled             = $true
        AdmissionControlEnabled = $true
        VMMonitoring          = "vmMonitoringOnly"
        HostMonitoring        = $true
        Hosts                 = @(
            @{ Name = "esxi-01.harbor.local"; ConnectionState = "Connected"; PowerState = "PoweredOn" }
            @{ Name = "esxi-02.harbor.local"; ConnectionState = "Connected"; PowerState = "PoweredOn" }
            @{ Name = "esxi-03.harbor.local"; ConnectionState = "Connected"; PowerState = "PoweredOn" }
        )
    }
}

# ---------------------------------------------------------------------------
# Live vCenter export functions (require PowerCLI)
# ---------------------------------------------------------------------------

function Connect-VCenter {
    <#
    .SYNOPSIS
        Establishes a connection to the target vCenter Server.
    #>
    Write-Log "Connecting to vCenter Server: $VCenterServer"
    try {
        if ($Credential) {
            $connection = Connect-VIServer -Server $VCenterServer -Credential $Credential -ErrorAction Stop
        }
        else {
            $connection = Connect-VIServer -Server $VCenterServer -ErrorAction Stop
        }
        Write-Log "Connected to $($connection.Name) (Version $($connection.Version))" -Level SUCCESS
        return $connection
    }
    catch {
        Write-Log "Failed to connect to vCenter: $_" -Level ERROR
        throw
    }
}

function Export-LiveVMInventory {
    <#
    .SYNOPSIS
        Collects VM inventory from a live vCenter connection.
    #>
    Write-Log "Collecting VM inventory from vCenter..."
    $vmParams = @{}
    if ($Datacenter) { $vmParams.Location = Get-Datacenter -Name $Datacenter }

    $allVMs = Get-VM @vmParams
    $vmList = [System.Collections.ArrayList]::new()

    $count = 0
    foreach ($vm in $allVMs) {
        $count++
        Write-ProgressStep -Activity "Exporting VM Inventory" `
            -Status "Processing $($vm.Name) ($count of $($allVMs.Count))" `
            -PercentComplete ([math]::Round(($count / $allVMs.Count) * 100))

        $guestInfo  = Get-VMGuest -VM $vm -ErrorAction SilentlyContinue
        $disks      = Get-HardDisk -VM $vm
        $nics       = Get-NetworkAdapter -VM $vm
        $snapshots  = Get-Snapshot -VM $vm -ErrorAction SilentlyContinue

        $vmObj = @{
            Name            = $vm.Name
            GuestOS         = $vm.GuestId
            PowerState      = $vm.PowerState.ToString()
            NumCpu          = $vm.NumCpu
            MemoryGB        = $vm.MemoryGB
            HardwareVersion = $vm.HardwareVersion
            VMToolsVersion  = $vm.ExtensionData.Guest.ToolsVersion
            VMToolsStatus   = $vm.ExtensionData.Guest.ToolsRunningStatus
            Folder          = $vm.Folder.Name
            ResourcePool    = $vm.ResourcePool.Name
            Cluster         = ($vm | Get-Cluster).Name
            Host            = $vm.VMHost.Name
            Disks           = @($disks | ForEach-Object {
                @{
                    Label         = $_.Name
                    CapacityGB    = [math]::Round($_.CapacityGB, 2)
                    StorageFormat = $_.StorageFormat.ToString()
                    Datastore     = $_.Filename.Split(']')[0].TrimStart('[')
                }
            })
            NetworkAdapters = @($nics | ForEach-Object {
                @{
                    Name        = $_.Name
                    Type        = $_.Type.ToString()
                    NetworkName = $_.NetworkName
                    MacAddress  = $_.MacAddress
                    Connected   = $_.ConnectionState.Connected
                }
            })
            Snapshots       = @($snapshots | ForEach-Object {
                @{
                    Name    = $_.Name
                    Created = $_.Created.ToString("o")
                    SizeGB  = [math]::Round($_.SizeGB, 2)
                }
            })
        }

        # IP addresses from guest info
        if ($guestInfo -and $guestInfo.IPAddress) {
            $vmObj.NetworkAdapters | ForEach-Object {
                $_.IPAddress = ($guestInfo.IPAddress | Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' }) -join ","
            }
        }

        [void]$vmList.Add($vmObj)
    }
    return $vmList
}

function Export-LiveNetworkTopology {
    Write-Log "Collecting network topology..."
    $switches = Get-VDSwitch
    $topology = @{
        DistributedSwitches = @($switches | ForEach-Object {
            @{
                Name       = $_.Name
                Version    = $_.Version
                MTU        = $_.Mtu
                NumPorts   = $_.NumPorts
                PortGroups = @(Get-VDPortgroup -VDSwitch $_ | ForEach-Object {
                    @{ Name = $_.Name; VLAN = $_.VlanConfiguration.VlanId }
                })
            }
        })
    }
    return $topology
}

function Export-LiveResourcePools {
    Write-Log "Collecting resource pools..."
    $pools = Get-ResourcePool | Where-Object { $_.Name -ne "Resources" }
    return @($pools | ForEach-Object {
        @{
            Name              = $_.Name
            CpuReservationMHz = $_.CpuReservationMHz
            CpuSharesLevel    = $_.CpuSharesLevel.ToString()
            MemReservationGB  = [math]::Round($_.MemReservationGB, 2)
            MemSharesLevel    = $_.MemSharesLevel.ToString()
            VMs               = @((Get-VM -Location $_).Name)
        }
    })
}

function Export-LiveDRSRules {
    Write-Log "Collecting DRS rules..."
    $clusters = Get-Cluster
    $rules = [System.Collections.ArrayList]::new()
    foreach ($cluster in $clusters) {
        $drsRules = Get-DrsRule -Cluster $cluster -ErrorAction SilentlyContinue
        foreach ($rule in $drsRules) {
            [void]$rules.Add(@{
                Name    = $rule.Name
                Type    = if ($rule.KeepTogether) { "affinity" } else { "anti-affinity" }
                Enabled = $rule.Enabled
                VMs     = @($rule.VMIds | ForEach-Object { (Get-VM -Id $_).Name })
            })
        }
    }
    return $rules
}

function Export-LiveHAConfig {
    Write-Log "Collecting HA configuration..."
    $clusters = Get-Cluster
    return @($clusters | ForEach-Object {
        @{
            ClusterName             = $_.Name
            HAEnabled               = $_.HAEnabled
            AdmissionControlEnabled = $_.HAAdmissionControlEnabled
            Hosts                   = @(Get-VMHost -Location $_ | ForEach-Object {
                @{ Name = $_.Name; ConnectionState = $_.ConnectionState.ToString(); PowerState = $_.PowerState.ToString() }
            })
        }
    })
}

# ---------------------------------------------------------------------------
# Main execution
# ---------------------------------------------------------------------------

try {
    Write-Log "=========================================="
    Write-Log "  Harbor Retail vCenter Inventory Export"
    Write-Log "=========================================="
    Write-Log "Mode: $(if ($Simulate) { 'SIMULATION' } else { 'LIVE' })"
    Write-Log "Target: $VCenterServer"
    Write-Log "Output: $OutputPath"
    Write-Log ""

    New-OutputDirectory

    if ($Simulate) {
        # ---- Simulated data collection ----
        Write-ProgressStep -Activity "Inventory Export (Simulated)" -Status "Collecting VMs..." -PercentComplete 10
        Write-Log "Collecting simulated VM inventory..."
        $vmInventory = Get-SimulatedVMInventory
        Start-Sleep -Milliseconds 300

        Write-ProgressStep -Activity "Inventory Export (Simulated)" -Status "Collecting network topology..." -PercentComplete 30
        Write-Log "Collecting simulated network topology..."
        $networkTopology = Get-SimulatedNetworkTopology
        Start-Sleep -Milliseconds 200

        Write-ProgressStep -Activity "Inventory Export (Simulated)" -Status "Collecting resource pools..." -PercentComplete 50
        Write-Log "Collecting simulated resource pools..."
        $resourcePools = Get-SimulatedResourcePools
        Start-Sleep -Milliseconds 200

        Write-ProgressStep -Activity "Inventory Export (Simulated)" -Status "Collecting DRS rules..." -PercentComplete 70
        Write-Log "Collecting simulated DRS rules..."
        $drsRules = Get-SimulatedDRSRules
        Start-Sleep -Milliseconds 200

        Write-ProgressStep -Activity "Inventory Export (Simulated)" -Status "Collecting HA config..." -PercentComplete 85
        Write-Log "Collecting simulated HA configuration..."
        $haConfig = Get-SimulatedHAConfig
        Start-Sleep -Milliseconds 200

        $performanceMetrics = $null
        if ($IncludePerformanceMetrics) {
            Write-ProgressStep -Activity "Inventory Export (Simulated)" -Status "Collecting performance metrics..." -PercentComplete 92
            Write-Log "Collecting simulated 30-day performance baselines..."
            $performanceMetrics = Get-SimulatedPerformanceMetrics
            Start-Sleep -Milliseconds 300
        }
    }
    else {
        # ---- Live vCenter collection ----
        $viConnection = Connect-VCenter

        Write-ProgressStep -Activity "Inventory Export (Live)" -Status "Collecting VMs..." -PercentComplete 10
        $vmInventory = Export-LiveVMInventory

        Write-ProgressStep -Activity "Inventory Export (Live)" -Status "Collecting network topology..." -PercentComplete 40
        $networkTopology = Export-LiveNetworkTopology

        Write-ProgressStep -Activity "Inventory Export (Live)" -Status "Collecting resource pools..." -PercentComplete 55
        $resourcePools = Export-LiveResourcePools

        Write-ProgressStep -Activity "Inventory Export (Live)" -Status "Collecting DRS rules..." -PercentComplete 70
        $drsRules = Export-LiveDRSRules

        Write-ProgressStep -Activity "Inventory Export (Live)" -Status "Collecting HA config..." -PercentComplete 85
        $haConfig = Export-LiveHAConfig

        $performanceMetrics = $null
        if ($IncludePerformanceMetrics) {
            Write-ProgressStep -Activity "Inventory Export (Live)" -Status "Collecting performance metrics..." -PercentComplete 92
            Write-Log "Collecting 30-day performance statistics (this may take several minutes)..."
            $performanceMetrics = @{}
            foreach ($vm in (Get-VM)) {
                $stats = Get-Stat -Entity $vm -Stat "cpu.usage.average", "mem.usage.average" `
                    -Start (Get-Date).AddDays(-30) -IntervalMins 1440 -ErrorAction SilentlyContinue
                $performanceMetrics[$vm.Name] = @{
                    Period          = "30-day average"
                    CpuUsagePercent = [math]::Round(($stats | Where-Object { $_.MetricId -eq "cpu.usage.average" } | Measure-Object -Property Value -Average).Average, 1)
                    MemUsagePercent = [math]::Round(($stats | Where-Object { $_.MetricId -eq "mem.usage.average" } | Measure-Object -Property Value -Average).Average, 1)
                }
            }
        }

        Disconnect-VIServer -Server $VCenterServer -Confirm:$false
        Write-Log "Disconnected from vCenter" -Level SUCCESS
    }

    # ---- Build consolidated report ----
    Write-ProgressStep -Activity "Inventory Export" -Status "Building report..." -PercentComplete 95

    $totalCpu      = ($vmInventory | Measure-Object -Property NumCpu -Sum).Sum
    $totalMemGB    = ($vmInventory | Measure-Object -Property MemoryGB -Sum).Sum
    $totalStorageGB = 0
    $totalUsedGB    = 0
    foreach ($vm in $vmInventory) {
        foreach ($disk in $vm.Disks) {
            $totalStorageGB += $disk.CapacityGB
            if ($disk.UsedGB) { $totalUsedGB += $disk.UsedGB }
        }
    }

    $report = [ordered]@{
        ExportMetadata = [ordered]@{
            ExportDate     = (Get-Date).ToString("o")
            VCenterServer  = $VCenterServer
            Mode           = if ($Simulate) { "Simulation" } else { "Live" }
            ScriptVersion  = "1.0.0"
            ExportDuration = $null
        }
        Summary        = [ordered]@{
            TotalVMs        = $vmInventory.Count
            TotalvCPUs      = $totalCpu
            TotalMemoryGB   = $totalMemGB
            TotalStorageGB  = $totalStorageGB
            TotalUsedGB     = $totalUsedGB
            Tiers           = @{
                Web = @($vmInventory | Where-Object { $_.ResourcePool -eq "Web-Pool" }).Count
                App = @($vmInventory | Where-Object { $_.ResourcePool -eq "App-Pool" }).Count
                DB  = @($vmInventory | Where-Object { $_.ResourcePool -eq "DB-Pool" }).Count
            }
        }
        VirtualMachines    = $vmInventory
        NetworkTopology    = $networkTopology
        ResourcePools      = $resourcePools
        DRSRules           = $drsRules
        HAConfiguration    = $haConfig
    }

    if ($performanceMetrics) {
        $report.PerformanceMetrics = $performanceMetrics
    }

    $duration = (Get-Date) - $script:StartTime
    $report.ExportMetadata.ExportDuration = "$([math]::Round($duration.TotalSeconds, 1))s"

    # ---- Write output files ----
    $consolidatedPath = Join-Path $OutputPath "vcenter-inventory-export.json"
    $report | ConvertTo-Json -Depth 15 | Set-Content -Path $consolidatedPath -Encoding UTF8
    Write-Log "Consolidated report: $consolidatedPath" -Level SUCCESS

    # Also write individual component files for downstream tooling
    $componentFiles = @{
        "vm-inventory.json"      = $vmInventory
        "network-topology.json"  = $networkTopology
        "resource-pools.json"    = $resourcePools
        "drs-rules.json"         = $drsRules
        "ha-config.json"         = $haConfig
    }
    if ($performanceMetrics) {
        $componentFiles["performance-metrics.json"] = $performanceMetrics
    }

    foreach ($file in $componentFiles.GetEnumerator()) {
        $filePath = Join-Path $OutputPath $file.Key
        $file.Value | ConvertTo-Json -Depth 10 | Set-Content -Path $filePath -Encoding UTF8
        Write-Log "  -> $filePath"
    }

    Write-Progress -Activity "Inventory Export" -Completed

    # ---- Summary ----
    Write-Log ""
    Write-Log "=========================================="
    Write-Log "  Export Complete"
    Write-Log "=========================================="
    Write-Log "VMs exported        : $($vmInventory.Count)"
    Write-Log "Total vCPUs         : $totalCpu"
    Write-Log "Total Memory        : $totalMemGB GB"
    Write-Log "Total Storage       : $totalStorageGB GB (Used: $totalUsedGB GB)"
    Write-Log "DRS rules           : $($drsRules.Count)"
    Write-Log "Resource pools      : $($resourcePools.Count)"
    Write-Log "Network segments    : $($networkTopology.LogicalSwitches.Count)"
    Write-Log "Duration            : $([math]::Round($duration.TotalSeconds, 1))s"
    Write-Log "Output directory    : $OutputPath" -Level SUCCESS
}
catch {
    Write-Log "FATAL: $($_.Exception.Message)" -Level ERROR
    Write-Log "Stack: $($_.ScriptStackTrace)" -Level ERROR
    exit 1
}
