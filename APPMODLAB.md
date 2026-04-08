---
title: "VMware to Azure VMware Solution Migration Lab"
description: >
  A hands-on lab that walks through migrating a multi-tier VMware application
  (Harbor Retail Group) to Azure VMware Solution using VMware HCX for zero-downtime
  migration, NSX-T for modern network micro-segmentation, and ExpressRoute for
  hybrid connectivity to Azure native services.
category: "Infrastructure Migration"
priority: "P1"
languages:
  - VMware
  - Azure
  - PowerShell
  - Terraform
products:
  - Azure VMware Solution
  - VMware HCX
  - NSX-T
  - ExpressRoute
  - Azure Monitor
  - Azure Backup
page_type: tutorial
urlFragment: vmware-to-azure-vmware-solution
ms.date: 04/08/2026
ms.author: Azure GBB Team
organization: "EmeaAppGbb"
difficulty: "Advanced"
duration: "6-8 hours (+ 3-4 hours AVS provisioning)"
repository: "appmodlab-vmware-to-azure-vmware-solution"
prerequisites:
  - "Azure subscription with AVS quota approved"
  - "VMware vSphere administration experience"
  - "Azure CLI and VMware PowerCLI installed"
  - "Basic networking knowledge (BGP, ExpressRoute, VLANs)"
learning_objectives:
  - "Assess VMware environments for Azure VMware Solution compatibility"
  - "Provision and configure an AVS private cloud using Terraform or Bicep"
  - "Deploy and configure VMware HCX for workload migration"
  - "Execute wave-based VM migrations with zero downtime using HCX vMotion"
  - "Migrate NSX-V firewall rules and segments to NSX-T distributed firewall"
  - "Establish hybrid connectivity between AVS and Azure via ExpressRoute"
  - "Configure Azure Backup and Azure Monitor for migrated workloads"
  - "Plan a post-migration modernization path toward Azure-native services"
tags:
  - VMware
  - AVS
  - HCX
  - NSX-T
  - Migration
  - Hybrid Cloud
  - ExpressRoute
  - Infrastructure
---

# VMware to Azure VMware Solution Migration Lab

**Category:** Infrastructure Migration  
**Difficulty:** Advanced  
**Duration:** 6–8 hours (+ 3–4 hours AVS provisioning)  
**Technologies:** VMware vSphere 7.0, Azure VMware Solution, VMware HCX, NSX-T, ExpressRoute, Terraform, Bicep, PowerCLI

---

## Overview

This lab demonstrates an end-to-end migration of a production VMware workload to **Azure VMware Solution (AVS)** using **VMware HCX** for zero-downtime live migration. You will take the **Harbor Retail Group** — a multi-tier retail application running on five VMs across three network segments — from an on-premises vSphere 7.0 environment to a fully operational AVS private cloud integrated with Azure native services.

The migration follows a structured, wave-based approach that mirrors real-world enterprise migrations: database tier first, then application tier, and finally the web tier. Along the way, you will reconfigure networking from legacy NSX-V to modern NSX-T, establish ExpressRoute hybrid connectivity, and integrate Azure Backup and Azure Monitor — positioning Harbor Retail for future cloud-native modernization.

### Why Azure VMware Solution?

AVS provides a seamless path for organizations with significant VMware investments:

- **Same VMware tools** — vCenter, vSphere, NSX-T, vSAN run natively on Azure
- **Zero application refactoring** — Lift-and-shift with no code changes required
- **Live migration** — HCX vMotion enables zero-downtime VM migration
- **Azure integration** — ExpressRoute connects AVS to Azure PaaS services
- **Compliance continuity** — Maintain existing VMware operational procedures

---

## Business Context: Harbor Retail Group

Harbor Retail Group operates a multi-tier e-commerce application running in an on-premises VMware data center. The application serves thousands of daily customers through an ASP.NET MVC web frontend, a .NET Web API backend, and a SQL Server 2019 database.

### Current Environment

| VM | OS | Role | vCPU | RAM | Storage | Network | IP Address |
|----|-----|------|------|-----|---------|---------|------------|
| WEB01 | Windows Server 2019 | IIS Web Server | 4 | 8 GB | 100 GB | Web-Segment (VLAN 10) | 10.10.10.11 |
| WEB02 | Windows Server 2019 | IIS Web Server | 4 | 8 GB | 100 GB | Web-Segment (VLAN 10) | 10.10.10.12 |
| APP01 | Windows Server 2019 | API Server | 8 | 16 GB | 200 GB | App-Segment (VLAN 20) | 10.10.20.11 |
| APP02 | Windows Server 2019 | API Server | 8 | 16 GB | 200 GB | App-Segment (VLAN 20) | 10.10.20.12 |
| DB01 | Windows Server 2019 | SQL Server 2019 | 16 | 64 GB | 500 GB | DB-Segment (VLAN 30) | 10.10.30.11 |

**Total Footprint:** 40 vCPUs · 112 GB RAM · 1,100 GB provisioned storage (646 GB used)

### Business Drivers

- **Data center lease expiring** — Must vacate on-premises facility within 6 months
- **Maintain VMware expertise** — Team has deep VMware skills; minimize retraining
- **Zero downtime requirement** — Retail platform cannot tolerate extended outages
- **Future modernization** — Position workloads for gradual Azure-native adoption
- **Compliance** — Maintain existing security controls during migration

---

## Learning Objectives

By completing this lab, you will:

1. **Assess VMware environments** for AVS compatibility using PowerCLI scripts that export vCenter inventory, validate hardware versions, and check HCX requirements
2. **Provision an AVS private cloud** using Terraform or Bicep, including a 3-node AV36 cluster with management networking
3. **Deploy and configure VMware HCX** including site pairing, network profiles, compute profiles, and service mesh creation
4. **Configure NSX-T networking** by creating segments, migrating NSX-V firewall rules to NSX-T distributed firewall, and setting up micro-segmentation
5. **Plan and execute wave-based migrations** using HCX vMotion for zero-downtime transfer of production VMs
6. **Validate migrated workloads** through end-to-end application testing, performance baseline comparison, and connectivity verification
7. **Establish hybrid connectivity** via ExpressRoute Global Reach and integrate with Azure Backup, Azure Monitor, and Azure Private DNS
8. **Design a post-migration modernization roadmap** that positions Harbor Retail for gradual adoption of Azure-native services

---

## Prerequisites

### Azure Subscription Requirements

> ⚠️ **Important:** AVS requires a quota request that can take 1–5 business days for approval. Submit this well before starting the lab.

```bash
# Request AVS quota (must be approved before provisioning)
az quota create \
  --resource-name "standardAv36Family" \
  --scope "/subscriptions/{subscription-id}/providers/Microsoft.Compute/locations/eastus" \
  --limit-object value=3 limit-object-type=LimitValue \
  --resource-type "dedicated"

# Verify quota approval
az vmware private-cloud list --query "[].{Name:name, Status:provisioningState}"
```

- Azure subscription with **Owner** or **Contributor** role
- AVS resource provider registered: `az provider register -n Microsoft.AVS`
- Minimum **3 AV36 nodes** quota approved in your target region
- ExpressRoute connectivity (or simulated lab environment)

### Required Tools

| Tool | Version | Installation |
|------|---------|-------------|
| Azure CLI | 2.50+ | `winget install Microsoft.AzureCLI` |
| VMware PowerCLI | 13.0+ | `Install-Module VMware.PowerCLI -Scope CurrentUser` |
| Terraform | 1.5+ | `winget install Hashicorp.Terraform` |
| Git | 2.40+ | `winget install Git.Git` |

```powershell
# Verify all tools are installed
az --version | Select-String "azure-cli"
Get-Module VMware.PowerCLI -ListAvailable | Select-Object Name, Version
terraform version
git --version
```

### Experience Requirements

- VMware vSphere administration (vCenter, ESXi, vMotion)
- Basic Azure portal and CLI usage
- Networking fundamentals (VLANs, subnets, firewalls, BGP basics)
- PowerShell scripting proficiency

---

## Architecture

### Migration Architecture

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                          HARBOR RETAIL MIGRATION ARCHITECTURE                   │
├─────────────────────────────────────────────────────────────────────────────────┤
│                                                                                 │
│  ON-PREMISES DATA CENTER              AZURE                                    │
│  ┌─────────────────────┐              ┌───────────────────────────────────┐     │
│  │  vCenter Server 7.0 │              │  Azure VMware Solution (AVS)     │     │
│  │  ┌───────────────┐  │   HCX        │  ┌─────────────────────────────┐ │     │
│  │  │  Harbor-DC01   │  │  Tunnel      │  │  AVS Private Cloud          │ │     │
│  │  │  ┌──────────┐ │  │ ══════════►  │  │  ┌───────────────────────┐ │ │     │
│  │  │  │ WEB01/02 │ │  │  vMotion     │  │  │ WEB01/02 (migrated)  │ │ │     │
│  │  │  │ VLAN 10  │ │  │  Zero        │  │  │ NSX-T Web-Segment    │ │ │     │
│  │  │  ├──────────┤ │  │  Downtime    │  │  ├───────────────────────┤ │ │     │
│  │  │  │ APP01/02 │ │  │              │  │  │ APP01/02 (migrated)  │ │ │     │
│  │  │  │ VLAN 20  │ │  │              │  │  │ NSX-T App-Segment    │ │ │     │
│  │  │  ├──────────┤ │  │              │  │  ├───────────────────────┤ │ │     │
│  │  │  │   DB01   │ │  │              │  │  │ DB01 (migrated)      │ │ │     │
│  │  │  │ VLAN 30  │ │  │              │  │  │ NSX-T DB-Segment     │ │ │     │
│  │  │  └──────────┘ │  │              │  │  └───────────────────────┘ │ │     │
│  │  │  NSX-V 6.4    │  │              │  │  NSX-T Manager             │ │     │
│  │  │  vSAN Storage  │  │              │  │  vSAN (AVS-managed)        │ │     │
│  │  └───────────────┘  │              │  └─────────────────────────────┘ │     │
│  └─────────────────────┘              │                                   │     │
│           │                            │  ┌─────────────────────────────┐ │     │
│           │  ExpressRoute              │  │  Azure Native Services     │ │     │
│           │  Global Reach              │  │  ┌───────┐ ┌────────────┐ │ │     │
│           └────────────────────────────│──│  │Monitor│ │   Backup   │ │ │     │
│                                        │  │  └───────┘ └────────────┘ │ │     │
│                                        │  │  ┌───────┐ ┌────────────┐ │ │     │
│                                        │  │  │Key    │ │ Private    │ │ │     │
│                                        │  │  │Vault  │ │ DNS        │ │ │     │
│                                        │  │  └───────┘ └────────────┘ │ │     │
│                                        │  └─────────────────────────────┘ │     │
│                                        └───────────────────────────────────┘     │
└─────────────────────────────────────────────────────────────────────────────────┘
```

### Network Topology After Migration

```
┌──────────────────────────────────────────────────────────────┐
│  NSX-T Segments (AVS)                                        │
│                                                              │
│  ┌──────────────┐    ┌──────────────┐    ┌──────────────┐   │
│  │ Web-Segment  │───►│ App-Segment  │───►│ DB-Segment   │   │
│  │ 10.10.10.0/24│    │ 10.10.20.0/24│    │ 10.10.30.0/24│   │
│  │ WEB01, WEB02 │    │ APP01, APP02 │    │ DB01         │   │
│  └──────┬───────┘    └──────────────┘    └──────────────┘   │
│         │                                                    │
│  ┌──────┴───────┐                                            │
│  │ NSX-T DFW    │  Micro-segmentation Rules:                 │
│  │ (Distributed │  • Web → App: Allow HTTPS (443)            │
│  │  Firewall)   │  • App → DB:  Allow SQL (1433)             │
│  │              │  • Web → DB:  DENY (implicit)              │
│  └──────────────┘                                            │
│                                                              │
│  Transit VNet: 10.200.0.0/16                                 │
│  AVS Management: 10.100.0.0/22                               │
└──────────────────────────────────────────────────────────────┘
```

---

## Lab Structure

### Branch Strategy

This lab uses a branch-based progression model. Each branch represents a checkpoint in the migration journey:

| Branch | Purpose | State |
|--------|---------|-------|
| `main` | Complete lab with APPMODLAB.md and all documentation | Reference |
| `legacy` | Starting state — VMware config exports, PowerCLI scripts, application code | Start here |
| `solution` | Final state — AVS deployed, all VMs migrated, Azure integrated | Answer key |
| `step-1-assessment` | Completed assessment with inventory export and compatibility report | Checkpoint |
| `step-2-avs-provision` | AVS private cloud provisioned with networking configured | Checkpoint |
| `step-3-hcx-setup` | HCX deployed, site paired, service mesh established | Checkpoint |
| `step-4-migration` | All VMs migrated via HCX in three waves | Checkpoint |
| `step-5-post-migration` | NSX-T configured, Azure services integrated, monitoring active | Checkpoint |

```bash
# Start the lab from the legacy branch
git checkout legacy

# At any point, compare your progress to a checkpoint
git diff step-2-avs-provision

# If stuck, view the solution for a specific step
git checkout step-3-hcx-setup -- harbor-retail-vmware/scripts/
```

### Repository Structure

```
appmodlab-vmware-to-azure-vmware-solution/
├── avs-deployment/                        # Infrastructure as Code
│   ├── terraform/
│   │   └── avs-provision.tf              # AVS + ExpressRoute + VNet
│   └── bicep/
│       ├── avs-resources.bicep           # AVS private cloud
│       └── avs-deployment.bicep          # Deployment orchestration
├── harbor-retail-vmware/                  # Harbor Retail case study
│   ├── application/                      # .NET application code
│   │   ├── HarborRetail.Web/            # ASP.NET MVC frontend
│   │   ├── HarborRetail.Api/            # Web API services
│   │   └── HarborRetail.Database/       # SQL Server schema
│   ├── vmware-config/                    # vCenter configuration exports
│   │   ├── vcenter-inventory.json       # Full VM inventory
│   │   ├── network-topology.json        # NSX-V + VDS configuration
│   │   ├── resource-pools.json          # Resource pool definitions
│   │   ├── ha-config.json               # vSphere HA configuration
│   │   └── drs-rules.json               # DRS affinity/anti-affinity rules
│   ├── vm-specs/                         # Per-VM detailed specifications
│   │   ├── web-tier/                    # WEB01, WEB02 specs + baselines
│   │   ├── app-tier/                    # APP01, APP02 specs + baselines
│   │   └── db-tier/                     # DB01 spec + SQL Server details
│   ├── networking/                       # Network configuration
│   │   ├── nsx-v-config/               # Legacy firewall rules
│   │   ├── nsx-t-migration-mapping.md  # NSX-V → NSX-T mapping guide
│   │   ├── load-balancer/              # LB configuration
│   │   └── dns-records.json            # DNS zone records
│   ├── scripts/                          # Automation scripts
│   │   ├── powercli/
│   │   │   ├── export-inventory.ps1    # vCenter inventory export
│   │   │   ├── assess-compatibility.ps1 # HCX compatibility checker
│   │   │   └── migration-runbook.ps1   # Wave-based migration automation
│   │   └── terraform/
│   │       └── avs-provision.tf        # AVS provisioning
│   └── documentation/
│       ├── runbook.md                   # Migration runbook
│       └── rollback-plan.md            # Rollback procedures
└── .github/workflows/
    └── avs-deployment.yml               # CI/CD pipeline
```

---

## Step-by-Step Instructions

### Step 1: Assess VMware Environment

**Objective:** Export the existing vCenter inventory, validate HCX compatibility, baseline performance, and produce a migration readiness report.

**Duration:** 1–2 hours

#### 1.1 Export vCenter Inventory

Run the PowerCLI inventory export script to capture the full state of the on-premises environment:

```powershell
# Connect to vCenter (or run in simulation mode for the lab)
cd harbor-retail-vmware/scripts/powercli

# Run inventory export (simulation mode for lab environment)
.\export-inventory.ps1 -SimulationMode

# For a live vCenter environment:
# .\export-inventory.ps1 -VCenterServer "vcenter.harbor.local" -Credential (Get-Credential)
```

**Expected Output:** JSON files in `harbor-retail-vmware/vmware-config/` containing:
- VM inventory (5 VMs with CPU, memory, disk, network details)
- Network topology (3 VLANs, NSX-V logical switches)
- Resource pool configuration
- DRS rules and HA configuration

#### 1.2 Run Compatibility Assessment

Validate that all VMs meet HCX and AVS requirements:

```powershell
# Run the compatibility assessment
.\assess-compatibility.ps1 -SimulationMode

# The script checks:
# - vSphere version compatibility (7.0+ required)
# - VM hardware version (≥13 for HCX)
# - VMware Tools status (must be running)
# - Snapshot presence (must be removed before migration)
# - Network adapter types (VMXNET3 recommended)
# - Disk configuration (no RDMs for vMotion)
# - EFI/BIOS boot compatibility
```

**Expected Results:**

| Check | WEB01 | WEB02 | APP01 | APP02 | DB01 |
|-------|-------|-------|-------|-------|------|
| Hardware Version | ✅ v15 | ✅ v15 | ✅ v15 | ✅ v15 | ✅ v15 |
| VMware Tools | ✅ Running | ✅ Running | ✅ Running | ✅ Running | ✅ Running |
| Snapshots | ✅ None | ✅ None | ✅ None | ✅ None | ✅ None |
| Network Adapter | ✅ VMXNET3 | ✅ VMXNET3 | ✅ VMXNET3 | ✅ VMXNET3 | ✅ VMXNET3 |
| Overall | ✅ Pass | ✅ Pass | ✅ Pass | ✅ Pass | ✅ Pass |

#### 1.3 Calculate AVS Capacity Requirements

```powershell
# The assessment script outputs capacity requirements:
# Total vCPUs: 40 → Requires minimum 2 AV36 nodes (36 cores each)
# Total RAM: 112 GB → Well within 576 GB per AV36 node
# Total Storage: 646 GB used → Well within vSAN capacity
# Recommendation: 3-node AV36 cluster (minimum for HA)
```

#### 1.4 Baseline Performance Metrics

Review the 30-day performance baselines captured in each VM spec file:

```powershell
# Review the performance baselines
Get-Content ..\vm-specs\web-tier\web01-spec.json | ConvertFrom-Json |
    Select-Object -ExpandProperty performanceBaseline

# Key baselines to document:
# WEB01: CPU 35% avg / 72% peak, Memory 55% avg / 78% peak
# APP01: CPU 42% avg / 78% peak, Memory 68% avg / 85% peak
# DB01:  CPU 48% avg / 88% peak, Memory 82% avg / 94% peak, 1800 read IOPS
```

> 📋 **Checkpoint:** You should have a complete inventory export, a compatibility report with all VMs passing, and documented performance baselines. Compare your results with `git diff step-1-assessment`.

---

### Step 2: Provision AVS Private Cloud

**Objective:** Deploy a 3-node AVS private cloud with ExpressRoute connectivity and a transit virtual network.

**Duration:** 30 minutes hands-on + 3–4 hours provisioning wait

> ⏳ **Pro Tip:** Start AVS provisioning first, then continue with documentation and planning while it deploys. AVS provisioning typically takes 3–4 hours.

#### 2.1 Configure Variables

**Using Terraform:**

```bash
cd avs-deployment/terraform

# Review and customize the variables
cat avs-provision.tf
```

Key configuration values:

| Parameter | Value | Purpose |
|-----------|-------|---------|
| `location` | eastus | Azure region |
| `avs_private_cloud_name` | pc-harbor-retail | AVS private cloud name |
| `avs_sku` | av36 | Node type (36 cores, 576 GB RAM) |
| `avs_cluster_size` | 3 | Minimum for production HA |
| `avs_management_cidr` | 10.100.0.0/22 | AVS management network |
| `vnet_address_space` | 10.200.0.0/16 | Transit VNet for Azure integration |

#### 2.2 Deploy with Terraform

```bash
# Initialize and validate
terraform init
terraform validate
terraform plan -out=avs-plan.tfplan

# Deploy (will take 3-4 hours for AVS provisioning)
terraform apply avs-plan.tfplan
```

**Or deploy with Bicep:**

```bash
cd avs-deployment/bicep

az deployment sub create \
  --location eastus \
  --template-file avs-deployment.bicep \
  --parameters \
    location=eastus \
    privateCloudName=pc-harbor-retail \
    clusterSize=3 \
    managementCIDR="10.100.0.0/22"
```

**Or deploy with Azure CLI (quickest for testing):**

```bash
# Create resource group
az group create --name Harbor-AVS-RG --location eastus

# Create AVS private cloud (3-4 hour operation)
az vmware private-cloud create \
  --name pc-harbor-retail \
  --resource-group Harbor-AVS-RG \
  --location eastus \
  --sku av36 \
  --cluster-size 3 \
  --network-block "10.100.0.0/22" \
  --accept-eula \
  --no-wait

# Monitor provisioning status
az vmware private-cloud show \
  --name pc-harbor-retail \
  --resource-group Harbor-AVS-RG \
  --query "{Name:name, Status:provisioningState, Endpoints:endpoints}" \
  --output table
```

#### 2.3 Verify Deployment

Once provisioning completes:

```bash
# Get AVS endpoints
az vmware private-cloud show \
  --name pc-harbor-retail \
  --resource-group Harbor-AVS-RG \
  --query "{
    vCenter: endpoints.vcsa,
    NSXTManager: endpoints.nsxtManager,
    HCXCloudManager: endpoints.hcxCloudManager
  }" --output table

# Get AVS credentials
az vmware private-cloud list-admin-credentials \
  --name pc-harbor-retail \
  --resource-group Harbor-AVS-RG
```

#### 2.4 Create Transit VNet and ExpressRoute Gateway

```bash
# Create transit VNet
az network vnet create \
  --name Harbor-Transit-VNet \
  --resource-group Harbor-AVS-RG \
  --address-prefix "10.200.0.0/16" \
  --subnet-name GatewaySubnet \
  --subnet-prefix "10.200.0.0/24"

# Create ExpressRoute gateway
az network vnet-gateway create \
  --name Harbor-ER-Gateway \
  --resource-group Harbor-AVS-RG \
  --vnet Harbor-Transit-VNet \
  --gateway-type ExpressRoute \
  --sku ErGw1AZ \
  --no-wait

# Create ExpressRoute authorization key
az vmware authorization create \
  --name harbor-er-auth \
  --private-cloud pc-harbor-retail \
  --resource-group Harbor-AVS-RG

# Connect ExpressRoute to VNet gateway (after gateway provisioning completes)
ER_CIRCUIT_ID=$(az vmware private-cloud show \
  --name pc-harbor-retail \
  --resource-group Harbor-AVS-RG \
  --query "circuit.expressRouteID" -o tsv)

AUTH_KEY=$(az vmware authorization show \
  --name harbor-er-auth \
  --private-cloud pc-harbor-retail \
  --resource-group Harbor-AVS-RG \
  --query "expressRouteAuthorizationKey" -o tsv)

az network vpn-connection create \
  --name Harbor-AVS-Connection \
  --resource-group Harbor-AVS-RG \
  --vnet-gateway1 Harbor-ER-Gateway \
  --express-route-circuit2 $ER_CIRCUIT_ID \
  --authorization-key $AUTH_KEY \
  --routing-weight 0
```

**Expected Terraform Outputs:**

| Output | Example Value |
|--------|---------------|
| `vcenter_endpoint` | `https://10.100.0.2` |
| `nsxt_manager_endpoint` | `https://10.100.0.3` |
| `hcx_cloud_manager_endpoint` | `https://10.100.0.9` |
| `expressroute_circuit_id` | `/subscriptions/.../expressRouteCircuits/...` |
| `transit_vnet_id` | `/subscriptions/.../virtualNetworks/Harbor-Transit-VNet` |

> 📋 **Checkpoint:** AVS private cloud is in `Succeeded` provisioning state. vCenter, NSX-T Manager, and HCX Cloud Manager endpoints are accessible. ExpressRoute gateway is connected. Compare with `git diff step-2-avs-provision`.

---

### Step 3: Set Up VMware HCX

**Objective:** Deploy HCX on both cloud and on-premises sides, create a site pairing, and establish the service mesh for migration.

**Duration:** 1–2 hours

#### 3.1 Activate HCX in AVS

HCX Cloud Manager is pre-deployed in AVS but must be activated:

```bash
# Enable HCX add-on in AVS
az vmware addon hcx create \
  --resource-group Harbor-AVS-RG \
  --private-cloud pc-harbor-retail \
  --offer "VMware MaaS Cloud Provider"

# Generate HCX activation key
az vmware addon hcx create \
  --resource-group Harbor-AVS-RG \
  --private-cloud pc-harbor-retail
```

#### 3.2 Deploy HCX Connector On-Premises

1. Download the HCX Connector OVA from the HCX Cloud Manager portal
2. Deploy OVA to your on-premises vCenter:

```powershell
# Deploy HCX Connector OVA (from vCenter or PowerCLI)
$ovaPath = "C:\Downloads\VMware-HCX-Connector-4.x.x.ova"
$vmHost = "esxi-host01.harbor.local"

# Import using PowerCLI
Import-VApp -Source $ovaPath -VMHost $vmHost -Name "HCX-Connector" `
  -DiskStorageFormat Thin -Force
```

3. Configure the HCX Connector:
   - Management IP: assign from management network
   - vCenter registration: `vcenter.harbor.local`
   - SSO credentials: administrator@vsphere.local

#### 3.3 Create Site Pairing

Connect the on-premises HCX Connector to the AVS HCX Cloud Manager:

1. Open HCX Connector UI → **Infrastructure** → **Site Pairing**
2. Enter AVS HCX Cloud Manager URL (from Step 2.3)
3. Provide AVS cloudadmin credentials
4. Accept the certificate and complete pairing

**Verification:**

```powershell
# Verify site pairing status via PowerCLI (if HCX module available)
# Or check the HCX UI:
# Site Pairing Status: Connected
# Tunnel Status: Up
# Interconnect Status: Green
```

#### 3.4 Create Network Profiles

Create network profiles for migration traffic:

| Profile | Purpose | Network | Gateway |
|---------|---------|---------|---------|
| Management | HCX appliance management | 10.10.1.0/24 | 10.10.1.1 |
| vMotion | Live migration traffic | 10.10.2.0/24 | 10.10.2.1 |
| Uplink | WAN connectivity to AVS | External | DHCP |

#### 3.5 Create Compute Profile and Service Mesh

1. **Compute Profile:** Select the cluster, datastore, and network profiles
2. **Service Mesh:** Create the interconnect between on-premises and AVS

```
Service Mesh Components:
├── Interconnect Appliance (IX)  — Encrypted tunnel
├── Network Extension (NE)       — L2 stretch (optional)
└── WAN Optimization (WO)        — Bandwidth optimization
```

**Validation:**

```powershell
# Verify service mesh health
# HCX UI → Infrastructure → Service Mesh
# Expected: All appliances show "Service Running" status
# Tunnel Status: Up
# Appliance Health: Green for IX, NE, WO
```

> 📋 **Checkpoint:** HCX site pairing is active, service mesh is healthy with all tunnels up. You can see the on-premises VMs in the HCX migration view. Compare with `git diff step-3-hcx-setup`.

---

### Step 4: Configure NSX-T Networking

**Objective:** Create NSX-T segments on AVS that mirror the on-premises network topology and configure distributed firewall rules.

**Duration:** 45 minutes – 1 hour

#### 4.1 Create NSX-T Segments

Create segments in AVS NSX-T Manager that correspond to the on-premises VLANs:

```bash
# Using Azure CLI to configure NSX-T segments via AVS
# Web Segment
az vmware workload-network segment create \
  --resource-group Harbor-AVS-RG \
  --private-cloud pc-harbor-retail \
  --segment-name "Web-Segment" \
  --connected-gateway "/infra/tier-1s/TNT##-T1" \
  --subnet dhcp-ranges="" gateway-address="10.10.10.1/24"

# App Segment
az vmware workload-network segment create \
  --resource-group Harbor-AVS-RG \
  --private-cloud pc-harbor-retail \
  --segment-name "App-Segment" \
  --connected-gateway "/infra/tier-1s/TNT##-T1" \
  --subnet dhcp-ranges="" gateway-address="10.10.20.1/24"

# DB Segment
az vmware workload-network segment create \
  --resource-group Harbor-AVS-RG \
  --private-cloud pc-harbor-retail \
  --segment-name "DB-Segment" \
  --connected-gateway "/infra/tier-1s/TNT##-T1" \
  --subnet dhcp-ranges="" gateway-address="10.10.30.1/24"
```

#### 4.2 Configure NSX-T Distributed Firewall Rules

Refer to `harbor-retail-vmware/networking/nsx-t-migration-mapping.md` for the full NSX-V to NSX-T mapping.

| NSX-V Rule | NSX-T Rule | Source | Destination | Service | Action |
|------------|-----------|--------|-------------|---------|--------|
| Allow-Web-to-App | DFW-Allow-Web-to-App | Web-Segment | App-Segment | HTTPS (443) | Allow |
| Allow-App-to-DB | DFW-Allow-App-to-DB | App-Segment | DB-Segment | SQL (1433) | Allow |
| Block-Web-to-DB | DFW-Block-Web-to-DB | Web-Segment | DB-Segment | Any | Drop |

Configure these rules via the NSX-T Manager UI:

1. **Security** → **Distributed Firewall** → **Add Policy**
2. Create policy: `Harbor-Retail-Segmentation`
3. Add rules in order (most specific first, default deny last)
4. **Publish** the firewall rules

#### 4.3 Configure DNS

```bash
# Create Azure Private DNS zone for harbor.local
az network private-dns zone create \
  --resource-group Harbor-AVS-RG \
  --name harbor.local

# Add DNS records matching on-premises configuration
az network private-dns record-set a add-record \
  --resource-group Harbor-AVS-RG \
  --zone-name harbor.local \
  --record-set-name web01 \
  --ipv4-address 10.10.10.11

az network private-dns record-set a add-record \
  --resource-group Harbor-AVS-RG \
  --zone-name harbor.local \
  --record-set-name web02 \
  --ipv4-address 10.10.10.12

az network private-dns record-set a add-record \
  --resource-group Harbor-AVS-RG \
  --zone-name harbor.local \
  --record-set-name app01 \
  --ipv4-address 10.10.20.11

az network private-dns record-set a add-record \
  --resource-group Harbor-AVS-RG \
  --zone-name harbor.local \
  --record-set-name app02 \
  --ipv4-address 10.10.20.12

az network private-dns record-set a add-record \
  --resource-group Harbor-AVS-RG \
  --zone-name harbor.local \
  --record-set-name db01 \
  --ipv4-address 10.10.30.11

# Link DNS zone to transit VNet
az network private-dns link vnet create \
  --resource-group Harbor-AVS-RG \
  --zone-name harbor.local \
  --name harbor-dns-link \
  --virtual-network Harbor-Transit-VNet \
  --registration-enabled false
```

> 📋 **Checkpoint:** Three NSX-T segments created matching on-premises topology. DFW rules enforce tier-based micro-segmentation. DNS records configured.

---

### Step 5: Plan Migration Waves

**Objective:** Design a wave-based migration strategy that minimizes risk and maintains application availability throughout the migration.

**Duration:** 30 minutes

#### 5.1 Wave Strategy

The migration follows a reverse-dependency order — databases first, then application servers, then web servers:

```
┌─────────────────────────────────────────────────────────────┐
│                    MIGRATION WAVE PLAN                       │
├─────────────┬──────────────┬────────────┬───────────────────┤
│   Wave      │   VMs        │   Method   │   Duration        │
├─────────────┼──────────────┼────────────┼───────────────────┤
│ Wave 1      │ DB01         │ Bulk       │ ~90 min           │
│ (Database)  │              │ Migration  │ (off-peak window) │
├─────────────┼──────────────┼────────────┼───────────────────┤
│ Wave 2      │ APP01, APP02 │ vMotion    │ ~45 min           │
│ (App Tier)  │              │ (live)     │ (zero downtime)   │
├─────────────┼──────────────┼────────────┼───────────────────┤
│ Wave 3      │ WEB01, WEB02 │ vMotion    │ ~30 min           │
│ (Web Tier)  │              │ (live)     │ (zero downtime)   │
└─────────────┴──────────────┴────────────┴───────────────────┘
```

#### 5.2 Migration Method Selection

| Method | Use Case | Downtime | Harbor Retail Usage |
|--------|----------|----------|---------------------|
| **HCX vMotion** | Production VMs requiring zero downtime | None (< 1s switchover) | APP01, APP02, WEB01, WEB02 |
| **Bulk Migration** | Large VMs or scheduled maintenance windows | Brief (reboot during cutover) | DB01 (500 GB, scheduled during off-peak) |
| **Cold Migration** | Powered-off or dev/test VMs | Full (VM powered off) | Not used in this lab |
| **Replication Assisted vMotion (RAV)** | Large VMs needing zero downtime | None | Alternative for DB01 if zero downtime required |

#### 5.3 Pre-Migration Checklist

```powershell
# Run the pre-migration validation
cd harbor-retail-vmware/scripts/powercli
.\migration-runbook.ps1 -Phase PreCheck -SimulationMode

# Pre-migration checklist:
# ✅ All VMs have VMware Tools running and up to date
# ✅ No snapshots on any VM
# ✅ HCX service mesh healthy
# ✅ NSX-T segments created on AVS
# ✅ DNS records configured
# ✅ Application baseline metrics captured
# ✅ Rollback plan reviewed (see documentation/rollback-plan.md)
# ✅ Stakeholders notified of migration window
```

> 📋 **Checkpoint:** Migration wave plan documented, all pre-migration checks pass, rollback plan reviewed with the team.

---

### Step 6: Execute Migration (3 Waves)

**Objective:** Migrate all 5 VMs from on-premises vCenter to AVS using HCX, following the wave plan.

**Duration:** 2–3 hours

#### 6.1 Wave 1 — Database Tier (DB01)

**Method:** Bulk Migration (scheduled during off-peak hours)  
**Estimated Duration:** 90 minutes

```powershell
# Execute Wave 1
.\migration-runbook.ps1 -Phase Wave1 -SimulationMode

# What happens during Wave 1:
# 1. Pre-check: Verify DB01 health, backup status, replication state
# 2. Initiate HCX Bulk Migration for DB01
# 3. Replication begins (500 GB, ~60 min depending on bandwidth)
# 4. Cutover scheduled (brief reboot during switchover)
# 5. DB01 powers on in AVS on DB-Segment
# 6. Post-check: SQL Server connectivity, database integrity
```

**Manual HCX steps (if not using the runbook script):**

1. Open HCX UI → **Services** → **Migration**
2. Select **DB01** from the inventory
3. Choose **Bulk Migration** as the migration type
4. Configure:
   - Target site: AVS (pc-harbor-retail)
   - Target compute: AVS Cluster
   - Target storage: vSAN Default Storage Policy
   - Target network: DB-Segment
5. Schedule cutover window
6. Click **Validate** then **Go**

**Wave 1 Validation:**

```powershell
# Verify DB01 migration
# From AVS vCenter:
Get-VM -Name "DB01" | Select-Object Name, PowerState, VMHost, NumCpu, MemoryGB

# Test SQL Server connectivity from APP01 (still on-premises)
Test-NetConnection -ComputerName 10.10.30.11 -Port 1433

# Verify database integrity
Invoke-Sqlcmd -ServerInstance "db01.harbor.local" -Query "
    SELECT name, state_desc, recovery_model_desc
    FROM sys.databases
    WHERE name LIKE 'HarborRetail%'
"
# Expected: HarborRetail (ONLINE), HarborRetail_Archive (ONLINE), HarborRetail_Staging (ONLINE)
```

#### 6.2 Wave 2 — Application Tier (APP01, APP02)

**Method:** HCX vMotion (zero downtime)  
**Estimated Duration:** 45 minutes

```powershell
# Execute Wave 2
.\migration-runbook.ps1 -Phase Wave2 -SimulationMode

# What happens during Wave 2:
# 1. Pre-check: Verify APP01/APP02 health, DB01 connectivity from AVS
# 2. Initiate HCX vMotion for APP01
# 3. Live migration (zero downtime, <1s switchover)
# 4. APP01 running on AVS, verify API health
# 5. Initiate HCX vMotion for APP02
# 6. APP02 running on AVS, verify API health
# 7. Post-check: API response times, DB connectivity
```

**Wave 2 Validation:**

```powershell
# Verify APP01 and APP02 migration
Get-VM -Name "APP01","APP02" | Select-Object Name, PowerState, VMHost

# Test API endpoints from each app server
Invoke-WebRequest -Uri "https://app01.harbor.local/api/products" -UseBasicParsing |
    Select-Object StatusCode
# Expected: 200

Invoke-WebRequest -Uri "https://app02.harbor.local/api/products" -UseBasicParsing |
    Select-Object StatusCode
# Expected: 200

# Verify app-to-database connectivity
Test-NetConnection -ComputerName 10.10.30.11 -Port 1433 -InformationLevel Detailed
```

#### 6.3 Wave 3 — Web Tier (WEB01, WEB02)

**Method:** HCX vMotion (zero downtime)  
**Estimated Duration:** 30 minutes

```powershell
# Execute Wave 3
.\migration-runbook.ps1 -Phase Wave3 -SimulationMode

# What happens during Wave 3:
# 1. Pre-check: Verify WEB01/WEB02 health
# 2. Initiate HCX vMotion for WEB01
# 3. WEB01 running on AVS, verify IIS
# 4. Initiate HCX vMotion for WEB02
# 5. WEB02 running on AVS, verify IIS
# 6. Post-check: Full end-to-end application test
```

**Wave 3 Validation:**

```powershell
# Verify WEB01 and WEB02 migration
Get-VM -Name "WEB01","WEB02" | Select-Object Name, PowerState, VMHost

# Test web endpoints
Invoke-WebRequest -Uri "https://web01.harbor.local" -UseBasicParsing |
    Select-Object StatusCode
# Expected: 200

# Full end-to-end validation: Web → App → DB
Invoke-WebRequest -Uri "https://portal.harbor.local/api/products" -UseBasicParsing |
    Select-Object StatusCode, Content
# Expected: 200 with product data from SQL Server
```

> 📋 **Checkpoint:** All 5 VMs are running on AVS. Application is fully functional end-to-end. No VMs remain on-premises. Compare with `git diff step-4-migration`.

---

### Step 7: Validate Migrated Environment

**Objective:** Perform comprehensive post-migration validation including performance baseline comparison, network connectivity, and application functionality.

**Duration:** 30 minutes – 1 hour

#### 7.1 Infrastructure Validation

```powershell
# Verify all VMs are running on AVS
Get-VM | Where-Object { $_.Name -match "WEB|APP|DB" } |
    Select-Object Name, PowerState, VMHost, NumCpu, MemoryGB |
    Format-Table -AutoSize

# Expected output:
# Name   PowerState  VMHost              NumCpu  MemoryGB
# ----   ----------  ------              ------  --------
# WEB01  PoweredOn   esx-01.avs.azure    4       8
# WEB02  PoweredOn   esx-02.avs.azure    4       8
# APP01  PoweredOn   esx-01.avs.azure    8       16
# APP02  PoweredOn   esx-02.avs.azure    8       16
# DB01   PoweredOn   esx-03.avs.azure    16      64
```

#### 7.2 Network Connectivity Validation

```powershell
# Verify segment connectivity
$tests = @(
    @{Name="Web→App"; Source="10.10.10.11"; Dest="10.10.20.11"; Port=443}
    @{Name="App→DB";  Source="10.10.20.11"; Dest="10.10.30.11"; Port=1433}
    @{Name="Web→DB (should fail)"; Source="10.10.10.11"; Dest="10.10.30.11"; Port=1433}
)

foreach ($test in $tests) {
    $result = Test-NetConnection -ComputerName $test.Dest -Port $test.Port
    Write-Host "$($test.Name): $($result.TcpTestSucceeded)"
}

# Expected:
# Web→App: True
# App→DB: True
# Web→DB (should fail): False  ← NSX-T DFW blocking direct access
```

#### 7.3 Performance Baseline Comparison

```powershell
# Compare post-migration performance against pre-migration baselines
# Acceptable variance: within 10% of on-premises baselines

$baselines = @{
    "WEB01" = @{CPU_Avg=35; Mem_Avg=55; IOPS_Read=120}
    "APP01" = @{CPU_Avg=42; Mem_Avg=68; IOPS_Read=450}
    "DB01"  = @{CPU_Avg=48; Mem_Avg=82; IOPS_Read=1800}
}

# Collect current metrics from vCenter performance counters
# and compare against baselines
# Flag any metric >10% degraded for investigation
```

#### 7.4 Application End-to-End Test

```powershell
# Test complete user workflow
$baseUrl = "https://portal.harbor.local"

# 1. Homepage loads
$home = Invoke-WebRequest -Uri $baseUrl -UseBasicParsing
Write-Host "Homepage: $($home.StatusCode)" # Expected: 200

# 2. API returns product data
$products = Invoke-RestMethod -Uri "$baseUrl/api/products"
Write-Host "Products returned: $($products.Count)" # Expected: >0

# 3. Database write test (if applicable)
$testOrder = @{productId=1; quantity=1} | ConvertTo-Json
$order = Invoke-RestMethod -Uri "$baseUrl/api/orders" -Method POST `
    -Body $testOrder -ContentType "application/json"
Write-Host "Order created: $($order.orderId)" # Expected: valid order ID
```

> 📋 **Checkpoint:** All VMs running on AVS, network segmentation enforced, performance within 10% of baseline, application fully functional.

---

### Step 8: Post-Migration Configuration

**Objective:** Configure Azure Backup for VM protection and Azure Monitor for centralized observability.

**Duration:** 30 minutes – 1 hour

#### 8.1 Configure Azure Backup for AVS

```bash
# Create Recovery Services vault
az backup vault create \
  --name Harbor-AVS-Vault \
  --resource-group Harbor-AVS-RG \
  --location eastus

# Register AVS private cloud with the vault
# (Configure via Azure Portal → Recovery Services vault → Backup → Azure VMware Solution)

# Create backup policy
az backup policy create \
  --resource-group Harbor-AVS-RG \
  --vault-name Harbor-AVS-Vault \
  --name HarborRetailPolicy \
  --policy '{
    "schedulePolicy": {
      "schedulePolicyType": "SimpleSchedulePolicy",
      "scheduleRunFrequency": "Daily",
      "scheduleRunTimes": ["2024-01-01T02:00:00Z"]
    },
    "retentionPolicy": {
      "retentionPolicyType": "LongTermRetentionPolicy",
      "dailySchedule": { "retentionDuration": { "count": 30, "durationType": "Days" } },
      "weeklySchedule": { "retentionDuration": { "count": 12, "durationType": "Weeks" } }
    }
  }'
```

**Backup Schedule:**

| VM | Backup Type | Schedule | Retention |
|----|-------------|----------|-----------|
| DB01 | Full + Transaction Log | Daily 2:00 AM / 15-min logs | 30 days / 12 weeks |
| APP01, APP02 | Full | Daily 3:00 AM | 30 days |
| WEB01, WEB02 | Full | Daily 4:00 AM | 14 days |

#### 8.2 Configure Azure Monitor

```bash
# Create Log Analytics workspace
az monitor log-analytics workspace create \
  --resource-group Harbor-AVS-RG \
  --workspace-name Harbor-AVS-Logs \
  --location eastus

# Enable diagnostics on AVS private cloud
WORKSPACE_ID=$(az monitor log-analytics workspace show \
  --resource-group Harbor-AVS-RG \
  --workspace-name Harbor-AVS-Logs \
  --query id -o tsv)

az monitor diagnostic-settings create \
  --name harbor-avs-diagnostics \
  --resource $(az vmware private-cloud show \
    --name pc-harbor-retail \
    --resource-group Harbor-AVS-RG \
    --query id -o tsv) \
  --workspace $WORKSPACE_ID \
  --logs '[{"categoryGroup":"allLogs","enabled":true}]' \
  --metrics '[{"category":"AllMetrics","enabled":true}]'
```

#### 8.3 Create Alert Rules

```bash
# CPU alert for DB01 (critical workload)
az monitor metrics alert create \
  --name "Harbor-DB01-HighCPU" \
  --resource-group Harbor-AVS-RG \
  --scopes $(az vmware private-cloud show \
    --name pc-harbor-retail \
    --resource-group Harbor-AVS-RG \
    --query id -o tsv) \
  --condition "avg Percentage CPU > 85" \
  --window-size 5m \
  --evaluation-frequency 1m \
  --severity 2 \
  --description "DB01 CPU usage exceeding 85% threshold"

# Memory alert
az monitor metrics alert create \
  --name "Harbor-HighMemory" \
  --resource-group Harbor-AVS-RG \
  --scopes $(az vmware private-cloud show \
    --name pc-harbor-retail \
    --resource-group Harbor-AVS-RG \
    --query id -o tsv) \
  --condition "avg Percentage Memory > 90" \
  --window-size 5m \
  --evaluation-frequency 1m \
  --severity 2 \
  --description "AVS cluster memory usage exceeding 90%"
```

> 📋 **Checkpoint:** Azure Backup configured with daily schedules. Azure Monitor collecting diagnostics. Alert rules active for CPU and memory thresholds.

---

### Step 9: Azure Integration

**Objective:** Connect AVS to Azure native services for a hybrid cloud operating model and establish the foundation for future modernization.

**Duration:** 30 minutes – 1 hour

#### 9.1 Configure ExpressRoute Global Reach

Connect on-premises network to AVS via ExpressRoute Global Reach for hybrid operations during transition:

```bash
# Enable Global Reach between on-premises ExpressRoute and AVS ExpressRoute
az vmware private-cloud add-identity-source \
  --resource-group Harbor-AVS-RG \
  --private-cloud pc-harbor-retail \
  --name "harbor-ad" \
  --alias "harbor.local" \
  --domain "harbor.local" \
  --base-user-dn "dc=harbor,dc=local" \
  --base-group-dn "dc=harbor,dc=local" \
  --primary-server "ldaps://10.10.1.10" \
  --ssl Enabled
```

#### 9.2 Azure Key Vault Integration

```bash
# Create Key Vault for Harbor Retail secrets
az keyvault create \
  --name harbor-retail-kv \
  --resource-group Harbor-AVS-RG \
  --location eastus \
  --enable-rbac-authorization true

# Store database connection string
az keyvault secret set \
  --vault-name harbor-retail-kv \
  --name "HarborRetail-DB-ConnectionString" \
  --value "Server=db01.harbor.local;Database=HarborRetail;Integrated Security=true;"
```

#### 9.3 Azure Storage for Backup Targets

```bash
# Create storage account for additional backup/archive
az storage account create \
  --name harborretailbackups \
  --resource-group Harbor-AVS-RG \
  --location eastus \
  --sku Standard_GRS \
  --kind StorageV2

# Create container for SQL backups
az storage container create \
  --name sql-backups \
  --account-name harborretailbackups
```

#### 9.4 Verify Azure Integration

```bash
# Verify all Azure services are connected
echo "=== AVS Private Cloud ==="
az vmware private-cloud show \
  --name pc-harbor-retail \
  --resource-group Harbor-AVS-RG \
  --query "{Status:provisioningState, Endpoints:endpoints}" -o table

echo "=== ExpressRoute Connection ==="
az network vpn-connection show \
  --name Harbor-AVS-Connection \
  --resource-group Harbor-AVS-RG \
  --query "{Status:connectionStatus, Type:connectionType}" -o table

echo "=== Backup Vault ==="
az backup vault show \
  --name Harbor-AVS-Vault \
  --resource-group Harbor-AVS-RG \
  --query "{Name:name, Status:properties.provisioningState}" -o table

echo "=== Log Analytics ==="
az monitor log-analytics workspace show \
  --resource-group Harbor-AVS-RG \
  --workspace-name Harbor-AVS-Logs \
  --query "{Name:name, Status:provisioningState}" -o table
```

> 📋 **Checkpoint:** All Azure native services integrated. ExpressRoute active. Key Vault, Backup, and Monitor operational. Compare with `git diff step-5-post-migration`.

---

## Estimated Duration

| Phase | Activity | Hands-On Time | Wait Time |
|-------|----------|---------------|-----------|
| Step 1 | Assess VMware Environment | 1–2 hours | — |
| Step 2 | Provision AVS Private Cloud | 30 min | 3–4 hours (provisioning) |
| Step 3 | Set Up HCX | 1–2 hours | — |
| Step 4 | Configure Networking | 45 min – 1 hour | — |
| Step 5 | Plan Migration Waves | 30 min | — |
| Step 6 | Execute Migration (3 waves) | 2–3 hours | — |
| Step 7 | Validate | 30 min – 1 hour | — |
| Step 8 | Post-Migration Configuration | 30 min – 1 hour | — |
| Step 9 | Azure Integration | 30 min – 1 hour | — |
| **Total** | | **6–8 hours hands-on** | **+ 3–4 hours AVS provisioning** |

> 💡 **Pro Tip:** Start AVS provisioning (Step 2) early in the day or overnight, then complete the remaining steps while it deploys. Steps 4–5 can be done in parallel with Step 2.

---

## Key Concepts Covered

### VMware HCX Migration Methods

| Method | Downtime | Best For | How It Works |
|--------|----------|----------|-------------|
| **vMotion** | Zero (< 1s) | Production critical VMs | Live memory + disk transfer |
| **Bulk Migration** | Brief reboot | Large VMs, scheduled windows | Replication + scheduled cutover |
| **Cold Migration** | Full | Powered-off / dev VMs | Offline disk copy |
| **RAV (Replication Assisted vMotion)** | Zero | Large VMs needing zero downtime | Replication + final vMotion switchover |

### NSX-V to NSX-T Migration

| Feature | NSX-V (Legacy) | NSX-T (AVS) |
|---------|----------------|-------------|
| Firewall | Edge Services Gateway | Distributed Firewall (DFW) |
| Segmentation | VLAN-backed port groups | Overlay segments |
| Load Balancing | NSX-V LB | NSX-T LB + Azure Front Door |
| Routing | NSX-V DLR | Tier-0 / Tier-1 gateways |
| Micro-segmentation | Limited | Full DFW with context-aware rules |

### AVS Architecture Tiers

```
┌──────────────────────────────────────────────────┐
│ Azure Portal / Azure CLI / ARM APIs              │  Management Plane
├──────────────────────────────────────────────────┤
│ AVS Private Cloud                                │
│  ├── vCenter Server (compute management)         │  VMware Control Plane
│  ├── NSX-T Manager (networking & security)       │
│  ├── HCX Manager (migration)                     │
│  └── vSAN (storage)                              │
├──────────────────────────────────────────────────┤
│ Azure Bare-Metal Infrastructure                  │  Infrastructure
│  └── Dedicated ESXi hosts (AV36/AV36P/AV52)     │
├──────────────────────────────────────────────────┤
│ ExpressRoute (hybrid connectivity)               │  Networking
│ Azure Virtual Network (native service access)    │
└──────────────────────────────────────────────────┘
```

---

## Troubleshooting

### Common Issues and Solutions

#### HCX Site Pairing Fails

**Symptom:** "Unable to connect to remote site" error during site pairing.

**Resolution:**
1. Verify network connectivity between on-premises HCX Connector and AVS HCX Cloud Manager (port 443)
2. Confirm the AVS HCX Cloud Manager URL is correct (check `az vmware private-cloud show`)
3. Ensure cloudadmin credentials are valid
4. Check that the HCX activation key has been applied

```bash
# Verify HCX endpoint accessibility
az vmware private-cloud show \
  --name pc-harbor-retail \
  --resource-group Harbor-AVS-RG \
  --query "endpoints.hcxCloudManager"
```

#### vMotion Migration Stalls

**Symptom:** Migration progress stops at a percentage and does not advance.

**Resolution:**
1. Check HCX service mesh appliance health
2. Verify there are no snapshots on the source VM
3. Ensure sufficient bandwidth on the WAN uplink
4. Check for storage I/O contention on the source datastore

```powershell
# Check for snapshots
Get-VM -Name "APP01" | Get-Snapshot
# Should return nothing — remove any snapshots before retrying
```

#### VMs Cannot Communicate After Migration

**Symptom:** Migrated VMs are online but cannot reach other tiers.

**Resolution:**
1. Verify VMs are connected to the correct NSX-T segment
2. Check NSX-T DFW rules allow the required traffic
3. Confirm gateway addresses match on each segment
4. Validate DNS resolution

```powershell
# From a migrated VM, test connectivity
Test-NetConnection -ComputerName 10.10.20.11 -Port 443
nslookup app01.harbor.local
```

#### AVS Provisioning Fails

**Symptom:** Private cloud stuck in `Failed` or `Updating` state.

**Resolution:**
1. Verify AVS quota is approved for the region
2. Check that the management CIDR (10.100.0.0/22) does not overlap with existing networks
3. Review Azure Activity Log for detailed error messages

```bash
az vmware private-cloud show \
  --name pc-harbor-retail \
  --resource-group Harbor-AVS-RG \
  --query "{Status:provisioningState, Error:extendedProperties}"

az monitor activity-log list \
  --resource-group Harbor-AVS-RG \
  --offset 2h \
  --query "[?status.value=='Failed'].{Op:operationName.localizedValue, Msg:status.localizedValue}"
```

#### SQL Server Connectivity Issues Post-Migration

**Symptom:** Application tier returns database connection errors after DB01 migration.

**Resolution:**
1. Verify DB01 IP address is unchanged (10.10.30.11)
2. Check SQL Server service is running on DB01
3. Confirm NSX-T DFW allows App-Segment → DB-Segment on port 1433
4. Test SQL connectivity directly:

```powershell
# From APP01
Test-NetConnection -ComputerName db01.harbor.local -Port 1433
Invoke-Sqlcmd -ServerInstance "db01.harbor.local" -Query "SELECT @@SERVERNAME, @@VERSION"
```

---

## Clean Up

> ⚠️ **Warning:** AVS private clouds incur significant costs (~$20–30/hour for a 3-node cluster). Delete resources when you are finished with the lab.

### Delete All Resources

**Option 1: Delete the entire resource group (recommended):**

```bash
# This deletes everything: AVS, VNet, Gateway, Backup vault, etc.
az group delete --name Harbor-AVS-RG --yes --no-wait

# Monitor deletion progress
az group show --name Harbor-AVS-RG --query "properties.provisioningState" 2>/dev/null || echo "Deleted"
```

**Option 2: Delete resources individually (if sharing a resource group):**

```bash
# Delete AVS private cloud first (takes ~2 hours)
az vmware private-cloud delete \
  --name pc-harbor-retail \
  --resource-group Harbor-AVS-RG \
  --yes --no-wait

# Delete ExpressRoute connection
az network vpn-connection delete \
  --name Harbor-AVS-Connection \
  --resource-group Harbor-AVS-RG

# Delete ExpressRoute gateway
az network vnet-gateway delete \
  --name Harbor-ER-Gateway \
  --resource-group Harbor-AVS-RG

# Delete VNet
az network vnet delete \
  --name Harbor-Transit-VNet \
  --resource-group Harbor-AVS-RG

# Delete backup vault (must remove all protected items first)
az backup vault delete \
  --name Harbor-AVS-Vault \
  --resource-group Harbor-AVS-RG \
  --yes

# Delete Log Analytics workspace
az monitor log-analytics workspace delete \
  --resource-group Harbor-AVS-RG \
  --workspace-name Harbor-AVS-Logs \
  --yes

# Delete Key Vault (soft-delete, purge if needed)
az keyvault delete --name harbor-retail-kv
az keyvault purge --name harbor-retail-kv
```

### On-Premises Cleanup

After confirming AVS is fully operational and backed up:

1. Remove HCX Connector appliance from on-premises vCenter
2. Decommission the source VMs (keep powered off for 30 days as a safety net)
3. Remove HCX site pairing and service mesh
4. Document final state for compliance records

---

## Next Steps and Modernization Path

After successfully migrating to AVS, Harbor Retail can pursue a phased modernization journey:

### Phase 1: Stabilize on AVS (Months 1–3)
- ✅ **Completed in this lab** — All workloads running on AVS
- Tune vSAN storage policies for performance
- Establish operational runbooks for the AVS environment
- Train operations team on NSX-T and AVS management

### Phase 2: Azure-Native Integration (Months 3–6)
- **Azure SQL Migration** — Migrate DB01 from SQL Server on VM to Azure SQL Managed Instance
- **Azure Front Door** — Replace on-premises load balancer with Azure-native ingress
- **Azure AD** — Federate identity from on-premises AD to Azure AD
- **Azure DevOps** — Implement CI/CD pipelines for application deployments

### Phase 3: Application Modernization (Months 6–12)
- **Containerize** — Package HarborRetail.Web and HarborRetail.Api as containers
- **Azure Kubernetes Service** — Deploy containers to AKS
- **Azure API Management** — Add API gateway with rate limiting and analytics
- **Azure Cache for Redis** — Implement caching for product catalog

### Phase 4: Cloud-Native (Months 12+)
- **Microservices decomposition** — Break monolithic API into bounded contexts
- **Event-driven architecture** — Introduce Azure Service Bus for async workflows
- **Serverless** — Move background jobs to Azure Functions
- **Decommission AVS** — Once all workloads are Azure-native, retire the AVS cluster

```
MODERNIZATION ROADMAP
═══════════════════════════════════════════════════════════════
  On-Prem        AVS              Hybrid           Cloud-Native
  VMware    ──►  AVS + Azure  ──► Azure SQL    ──► AKS + PaaS
  NSX-V         NSX-T + Azure    + AKS + PaaS     Fully Azure
                 Monitor                            Native
═══════════════════════════════════════════════════════════════
  This Lab       Phase 2          Phase 3          Phase 4
  (Today)        (3-6 months)     (6-12 months)    (12+ months)
```

---

## Resources

- [Azure VMware Solution Documentation](https://learn.microsoft.com/azure/azure-vmware/)
- [VMware HCX Documentation](https://docs.vmware.com/en/VMware-HCX/)
- [NSX-T Data Center Documentation](https://docs.vmware.com/en/VMware-NSX-T-Data-Center/)
- [AVS Networking and Connectivity](https://learn.microsoft.com/azure/azure-vmware/concepts-networking)
- [Azure VMware Solution Well-Architected Framework](https://learn.microsoft.com/azure/well-architected/azure-vmware/)
- [HCX Migration Types Comparison](https://docs.vmware.com/en/VMware-HCX/services/user-guide/GUID-8A31731C-AA28-4714-9C23-D9E924DBB666.html)

---

*Built with 💜 by the Azure Global Black Belt team · EMEA App Modernization*
