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
