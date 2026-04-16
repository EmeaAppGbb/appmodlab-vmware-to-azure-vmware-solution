---
title: "VMware to Azure VMware Solution"
description: "Migrate VMware environments to AVS with HCX, NSX-T networking & ExpressRoute hybrid connectivity"
authors: ["marconsilva"]
category: "Infra Modernization"
industry: "Retail & Consumer Goods"
services: ["Azure VMware Solution", "Azure ExpressRoute", "Azure Backup", "Azure Monitor"]
languages: [".NET", "PowerShell"]
frameworks: []
modernizationTools: ["VMware HCX", "NSX-T", "Bicep", "Terraform"]
agenticTools: []
tags: ["vmware", "avs", "hcx", "nsx-t", "hybrid-cloud"]
extensions: ["github.copilot"]
thumbnail: ""
video: ""
version: "1.0.0"
screenshots:
  - path: "assets/screenshots/01-vcenter-inventory.html"
    alt: "vCenter Inventory — 5 VMs across Web, App, and DB tiers with resource details"
  - path: "assets/screenshots/02-network-topology.html"
    alt: "Network topology — NSX-V distributed switch, logical switches, and firewall rules"
  - path: "assets/screenshots/03-db01-spec.html"
    alt: "DB01 VM Spec — SQL Server 2019 Enterprise with 700 GB storage and performance baselines"
  - path: "assets/screenshots/04-avs-bicep-deployment.html"
    alt: "AVS Bicep deployment — Private cloud provisioning with AV36 SKU and ExpressRoute"
  - path: "assets/screenshots/05-migration-runbook.html"
    alt: "HCX migration runbook — Three-wave PowerCLI strategy with pre/post validation"
  - path: "assets/screenshots/06-nsx-t-migration-mapping.html"
    alt: "NSX-V to NSX-T migration mapping — Firewall rules, segments, and load balancer strategy"
---

# VMware to Azure VMware Solution

## Overview

This lab migrates Harbor Retail Group's VMware environment to Azure VMware Solution (AVS) using HCX for live migration, NSX-T for networking, and ExpressRoute for hybrid connectivity. The fleet consists of 5 VMs across web, app, and database tiers.

## Assessment Phase

### vCenter Inventory

The vCenter inventory shows 5 VMs across Web, App, and DB tiers with their resource allocations, providing the baseline for AVS sizing and HCX compatibility validation.

[View: vCenter Inventory](assets/screenshots/01-vcenter-inventory.html)

*Open the HTML file in a browser to view the syntax-highlighted rendering.*

### Network Topology

The on-premises network topology documents the NSX-V distributed switch, logical switches, and firewall rules that must be mapped to NSX-T equivalents on AVS.

[View: Network Topology](assets/screenshots/02-network-topology.html)

*Open the HTML file in a browser to view the syntax-highlighted rendering.*

### Database Server Specification

DB01 runs SQL Server 2019 Enterprise with 700 GB storage and established performance baselines. This is the most critical VM in the migration and drives AVS node sizing.

[View: DB01 VM Specification](assets/screenshots/03-db01-spec.html)

*Open the HTML file in a browser to view the syntax-highlighted rendering.*

## AVS Deployment

### Bicep Infrastructure as Code

The AVS private cloud is provisioned using Bicep templates with AV36 SKU nodes and ExpressRoute connectivity for hybrid integration.

[View: AVS Bicep Deployment](assets/screenshots/04-avs-bicep-deployment.html)

*Open the HTML file in a browser to view the syntax-highlighted rendering.*

## Migration Execution

### HCX Migration Runbook

The migration runbook defines a three-wave PowerCLI strategy (DB → App → Web) with pre-migration validation, live vMotion execution, and post-migration verification steps.

[View: HCX Migration Runbook](assets/screenshots/05-migration-runbook.html)

*Open the HTML file in a browser to view the syntax-highlighted rendering.*

## Post-Migration Networking

### NSX-V to NSX-T Migration Mapping

The NSX-T mapping documents how legacy NSX-V firewall rules, segments, and load balancer configurations translate to NSX-T distributed firewall policies and gateway services on AVS.

[View: NSX-T Migration Mapping](assets/screenshots/06-nsx-t-migration-mapping.html)

*Open the HTML file in a browser to view the syntax-highlighted rendering.*

## Screenshots

Visual walkthroughs of the VMware environment and migration artifacts. Open the HTML files in a browser for syntax-highlighted views.

| # | Screenshot | Description |
|---|-----------|-------------|
| 1 | [vCenter Inventory](assets/screenshots/01-vcenter-inventory.html) | 5 VMs across Web, App, and DB tiers with resource details |
| 2 | [Network Topology](assets/screenshots/02-network-topology.html) | NSX-V distributed switch, logical switches, and firewall rules |
| 3 | [DB01 VM Spec](assets/screenshots/03-db01-spec.html) | SQL Server 2019 Enterprise with 700 GB storage and performance baselines |
| 4 | [AVS Bicep Deployment](assets/screenshots/04-avs-bicep-deployment.html) | Private cloud provisioning with AV36 SKU and ExpressRoute |
| 5 | [Migration Runbook](assets/screenshots/05-migration-runbook.html) | Three-wave PowerCLI strategy with pre/post validation |
| 6 | [NSX-T Migration Mapping](assets/screenshots/06-nsx-t-migration-mapping.html) | Firewall rules, segments, and load balancer strategy |

## Solution Walkthrough

This walkthrough was generated using **GitHub Copilot CLI** (`gh copilot`) in autonomous mode. Each step was executed with a targeted prompt, and all CLI outputs were captured to `assets/outputs/`.

**Branch:** `solution-final` · **Tags:** `step-01-assessment` through `step-09-azure-integration`

### Step 1: Assess VMware Environment
```bash
gh copilot -- -p "Step 1: Assess VMware Environment. Review vmware-config/ files and assess-compatibility.ps1. Create assessment-report.md documenting VM inventory, network topology, HCX compatibility, storage analysis, AVS sizing, and migration risks. Update assess-compatibility.ps1 with AVS node sizing function." --allow-all-tools --yolo
```
**Output:** [`assets/outputs/step-01-assessment.txt`](assets/outputs/step-01-assessment.txt)
**Files created:** `harbor-retail-vmware/documentation/assessment-report.md` · Updated `assess-compatibility.ps1`

### Step 2: Provision AVS Private Cloud
```bash
gh copilot -- -p "Step 2: Provision AVS Private Cloud. Create Bicep parameters file, deploy-avs.ps1 deployment script with prerequisite validation, and configure-expressroute.ps1 for ExpressRoute Global Reach setup." --allow-all-tools --yolo
```
**Output:** [`assets/outputs/step-02-avs-provision.txt`](assets/outputs/step-02-avs-provision.txt)
**Files created:** `avs-deployment/bicep/avs-deployment.parameters.json` · `avs-deployment/scripts/deploy-avs.ps1` · `avs-deployment/scripts/configure-expressroute.ps1`

### Step 3: Set Up VMware HCX
```bash
gh copilot -- -p "Step 3: Set Up VMware HCX. Create configure-hcx.ps1 for HCX activation, site pairing, compute/network profiles, and service mesh. Create hcx-network-profiles.json config. Update runbook.md with HCX setup instructions." --allow-all-tools --yolo
```
**Output:** [`assets/outputs/step-03-hcx-setup.txt`](assets/outputs/step-03-hcx-setup.txt)
**Files created:** `harbor-retail-vmware/scripts/powercli/configure-hcx.ps1` · `harbor-retail-vmware/scripts/powercli/hcx-network-profiles.json` · Updated `runbook.md`

### Step 4: Configure NSX-T Networking
```bash
gh copilot -- -p "Step 4: Configure NSX-T Networking. Create nsx-t-config/ directory with segments.json, firewall-rules.json, and gateway-config.json mapping NSX-V rules to NSX-T equivalents. Update dns-records.json with AVS endpoints." --allow-all-tools --yolo
```
**Output:** [`assets/outputs/step-04-networking.txt`](assets/outputs/step-04-networking.txt)
**Files created:** `harbor-retail-vmware/networking/nsx-t-config/segments.json` · `firewall-rules.json` · `gateway-config.json` · Updated `dns-records.json`

### Step 5: Plan Migration Waves
```bash
gh copilot -- -p "Step 5: Plan Migration Waves. Create migration-waves.md with 3-wave plan (DB→App→Web) including checklists, durations, rollback criteria. Create validate-pre-migration.ps1 for VM readiness checks." --allow-all-tools --yolo
```
**Output:** [`assets/outputs/step-05-migration-waves.txt`](assets/outputs/step-05-migration-waves.txt)
**Files created:** `harbor-retail-vmware/documentation/migration-waves.md` · `harbor-retail-vmware/scripts/powercli/validate-pre-migration.ps1`

### Step 6: Execute VM Migration
```bash
gh copilot -- -p "Step 6: Execute VM Migration with HCX. Create execute-migration.ps1 for wave-based HCX migration (Bulk for DB, vMotion for App/Web). Create monitor-migration.ps1 for real-time migration dashboard." --allow-all-tools --yolo
```
**Output:** [`assets/outputs/step-06-migration.txt`](assets/outputs/step-06-migration.txt)
**Files created:** `harbor-retail-vmware/scripts/powercli/execute-migration.ps1` · `harbor-retail-vmware/scripts/powercli/monitor-migration.ps1`

### Step 7: Validate Post-Migration
```bash
gh copilot -- -p "Step 7: Validate Post-Migration. Create validate-post-migration.ps1 checking all 5 VMs on AVS (power, IPs, services, connectivity). Create validate-nsx-t-rules.ps1 for firewall rule verification." --allow-all-tools --yolo
```
**Output:** [`assets/outputs/step-07-validation.txt`](assets/outputs/step-07-validation.txt)
**Files created:** `harbor-retail-vmware/scripts/powercli/validate-post-migration.ps1` · `harbor-retail-vmware/scripts/powercli/validate-nsx-t-rules.ps1`

### Step 8: Post-Migration Configuration
```bash
gh copilot -- -p "Step 8: Post-Migration Configuration. Enhance configure-backup.ps1 with vault creation and tiered policies. Enhance configure-monitoring.ps1 with Log Analytics and alert rules. Create configure-identity.ps1 for AD DS extension to AVS." --allow-all-tools --yolo
```
**Output:** [`assets/outputs/step-08-post-migration.txt`](assets/outputs/step-08-post-migration.txt)
**Files updated:** `avs-deployment/scripts/configure-backup.ps1` · `configure-monitoring.ps1` · **Created:** `configure-identity.ps1`

### Step 9: Azure Integration
```bash
gh copilot -- -p "Step 9: Azure Integration. Create azure-integration.bicep with Private DNS zones, private endpoints, Front Door, VNet peering. Create configure-azure-services.ps1 for deployment. Create azure-integration-guide.md with architecture and modernization roadmap." --allow-all-tools --yolo
```
**Output:** [`assets/outputs/step-09-azure-integration.txt`](assets/outputs/step-09-azure-integration.txt)
**Files created:** `avs-deployment/bicep/azure-integration.bicep` · `avs-deployment/scripts/configure-azure-services.ps1` · `harbor-retail-vmware/documentation/azure-integration-guide.md`

### Reproducing the Solution
```bash
git clone https://github.com/EmeaAppGbb/appmodlab-vmware-to-azure-vmware-solution.git
cd appmodlab-vmware-to-azure-vmware-solution
git checkout solution-final

# View each step
git log --oneline --tags

# Checkout a specific step
git checkout step-01-assessment
```
