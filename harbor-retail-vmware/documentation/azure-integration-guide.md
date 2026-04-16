# Harbor Retail — Azure Integration Guide

## Overview

This guide describes the architecture and configuration for connecting Azure VMware
Solution (AVS) workloads to Azure native services via ExpressRoute, Private Endpoints,
and DNS forwarding. It covers the current integration topology, the DNS resolution flow,
and the future modernization roadmap for moving workloads to Azure-native PaaS services.

| Item | Value |
|------|-------|
| AVS Private Cloud | pc-harbor-retail |
| Transit VNet | vnet-harbor-retail-transit (10.200.0.0/16) |
| Application VNet | vnet-harbor-retail-app (10.210.0.0/16) |
| Private Endpoint Subnet | snet-private-endpoints (10.210.1.0/24) |
| ExpressRoute Gateway | ergw-harbor-retail |
| Azure Front Door | afd-harbor-retail |

---

## ExpressRoute Global Reach Architecture

The following diagram shows the end-to-end network path from on-premises, through AVS,
and into Azure native services via ExpressRoute and VNet peering.

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                          On-Premises Data Center                            │
│  ┌──────────────┐    ┌───────────────────┐                                  │
│  │ vSphere 7.0  │    │ ExpressRoute      │                                  │
│  │ (source VMs) │    │ Circuit (on-prem) │                                  │
│  └──────────────┘    └────────┬──────────┘                                  │
└───────────────────────────────┼─────────────────────────────────────────────┘
                                │
                    ┌───────────▼───────────┐
                    │   ExpressRoute        │
                    │   Global Reach        │
                    │   (direct peering)    │
                    └───────────┬───────────┘
                                │
┌───────────────────────────────┼─────────────────────────────────────────────┐
│  Azure VMware Solution        │                                             │
│  ┌────────────────────────────▼──────────────────────────────┐              │
│  │ AVS Private Cloud (pc-harbor-retail)                      │              │
│  │  ┌──────────┐  ┌──────────┐  ┌──────────┐               │              │
│  │  │  WEB01   │  │  APP01   │  │   DB01   │               │              │
│  │  │  WEB02   │  │  APP02   │  │          │               │              │
│  │  └──────────┘  └──────────┘  └──────────┘               │              │
│  │  Management CIDR: 10.100.0.0/22                          │              │
│  │  NSX-T DNS → Conditional Forwarder → 10.200.0.10         │              │
│  └───────────────────────────┬───────────────────────────────┘              │
│                              │ AVS Managed ExpressRoute                     │
└──────────────────────────────┼──────────────────────────────────────────────┘
                               │
              ┌────────────────▼─────────────────┐
              │  ExpressRoute Gateway             │
              │  ergw-harbor-retail               │
              │  (vnet-harbor-retail-transit)     │
              └────────────────┬─────────────────┘
                               │
        ┌──────────────────────▼──────────────────────┐
        │  Transit VNet (10.200.0.0/16)               │
        │  ┌────────────────────────────────────┐     │
        │  │ DNS Private Resolver / Forwarder   │     │
        │  │ 10.200.0.10                        │     │
        │  └────────────────────────────────────┘     │
        └──────────────────────┬──────────────────────┘
                               │ VNet Peering
        ┌──────────────────────▼──────────────────────┐
        │  Application VNet (10.210.0.0/16)           │
        │                                              │
        │  ┌──────────────────────────────────────┐   │
        │  │ snet-private-endpoints (10.210.1.0/24)│   │
        │  │  ┌──────────────────┐                │   │
        │  │  │ pe-sql (1433)    │ → Azure SQL DB │   │
        │  │  │ pe-blob (443)    │ → Blob Storage │   │
        │  │  └──────────────────┘                │   │
        │  └──────────────────────────────────────┘   │
        │                                              │
        │  ┌──────────────────────────────────────┐   │
        │  │ snet-app-workloads (10.210.2.0/24)   │   │
        │  └──────────────────────────────────────┘   │
        └──────────────────────────────────────────────┘
                               │
              ┌────────────────▼─────────────────┐
              │  Azure Front Door                 │
              │  afd-harbor-retail                │
              │  (public ingress → web tier)      │
              └──────────────────────────────────┘
```

---

## Private Endpoint Connectivity Patterns

Private endpoints provide secure, private-IP access to Azure PaaS services without
exposing traffic to the public internet.

### Deployed Private Endpoints

| Endpoint | Target Service | Private Link Group | Subnet | Port |
|----------|---------------|-------------------|--------|------|
| pe-harbor-retail-sql | sql-harbor-retail.database.windows.net | sqlServer | snet-private-endpoints | 1433 |
| pe-harbor-retail-blob | stharborretail.blob.core.windows.net | blob | snet-private-endpoints | 443 |

### Traffic Flow

1. **AVS VM → Private Endpoint (SQL)**
   - APP01 opens connection to `sql-harbor-retail.database.windows.net:1433`
   - NSX-T DNS conditionally forwards `*.database.windows.net` to 10.200.0.10
   - Azure Private DNS resolves to private IP (e.g., 10.210.1.4)
   - Traffic routes: AVS ER → Transit VNet → VNet Peering → App VNet PE subnet
   - NSG `nsg-harbor-retail-pe` allows port 1433 from AVS CIDR

2. **AVS VM → Private Endpoint (Blob)**
   - WEB01 requests assets from `stharborretail.blob.core.windows.net`
   - DNS resolves to private IP (e.g., 10.210.1.5) via same forwarding chain
   - Traffic routes over the same ExpressRoute + peering path
   - NSG allows port 443 from AVS CIDR

3. **Public Internet → Web Tier (Front Door)**
   - End users connect to `fde-harbor-retail-web.z01.azurefd.net`
   - Azure Front Door terminates TLS and routes to backend origin (WEB01/WEB02)
   - NSG `nsg-harbor-retail-app` allows only `AzureFrontDoor.Backend` service tag

### NSG Rules Summary

| NSG | Rule | Priority | Direction | Source | Dest Port | Action |
|-----|------|----------|-----------|--------|-----------|--------|
| nsg-harbor-retail-pe | AllowSqlFromAvs | 100 | Inbound | 10.100.0.0/22 | 1433 | Allow |
| nsg-harbor-retail-pe | AllowBlobFromAvs | 110 | Inbound | 10.100.0.0/22 | 443 | Allow |
| nsg-harbor-retail-pe | AllowSqlFromAppSubnet | 120 | Inbound | 10.210.2.0/24 | 1433 | Allow |
| nsg-harbor-retail-pe | AllowBlobFromAppSubnet | 130 | Inbound | 10.210.2.0/24 | 443 | Allow |
| nsg-harbor-retail-pe | DenyAllInbound | 4096 | Inbound | * | * | Deny |
| nsg-harbor-retail-app | AllowHttpsFromFrontDoor | 100 | Inbound | AzureFrontDoor.Backend | 443 | Allow |
| nsg-harbor-retail-app | AllowHttpFromFrontDoor | 110 | Inbound | AzureFrontDoor.Backend | 80 | Allow |

---

## DNS Resolution Flow

AVS workloads resolve Azure private-link FQDNs through a multi-hop forwarding chain.

```
┌─────────────────┐     ┌─────────────────────┐     ┌──────────────────────┐
│  AVS VM         │     │  Azure DNS Private   │     │  Azure Private DNS   │
│  (e.g., APP01)  │     │  Resolver / Forwarder│     │  Zone                │
│                 │     │  10.200.0.10         │     │                      │
│  NSX-T DNS      │────▶│  (Transit VNet)      │────▶│  privatelink.        │
│  service        │     │                      │     │  database.windows.net│
│                 │     │  Forwards queries    │     │                      │
│                 │     │  for privatelink.*   │     │  A record:           │
│                 │     │  zones               │     │  10.210.1.4          │
└─────────────────┘     └─────────────────────┘     └──────────────────────┘
```

### Step-by-Step Resolution

1. **APP01** queries `sql-harbor-retail.database.windows.net`
2. **NSX-T DNS service** has a conditional forwarder:
   - `privatelink.database.windows.net` → `10.200.0.10`
   - `privatelink.blob.core.windows.net` → `10.200.0.10`
3. **Azure DNS Private Resolver** (or DNS forwarder VM at 10.200.0.10) receives the
   query and resolves it using Azure-provided DNS (168.63.129.16)
4. Azure DNS sees the Private DNS zone `privatelink.database.windows.net` linked to
   the transit VNet and returns the **private IP** of the private endpoint
5. APP01 connects to **10.210.1.4:1433** (private endpoint in the app VNet)
6. Traffic flows: AVS ExpressRoute → Transit VNet → VNet Peering → App VNet

### NSX-T DNS Configuration Steps

1. Open **NSX-T Manager** → Networking → DNS Services
2. Select the default DNS service attached to the Tier-1 gateway
3. Add **conditional forwarder zones**:
   - Zone: `privatelink.database.windows.net` → Upstream DNS: `10.200.0.10`
   - Zone: `privatelink.blob.core.windows.net` → Upstream DNS: `10.200.0.10`
4. Save and verify with `nslookup sql-harbor-retail.database.windows.net` from a VM

---

## Future Modernization Roadmap

The AVS migration is Phase 1 (lift-and-shift). The following phases incrementally
modernize workloads from AVS VMs to Azure-native PaaS services.

### Phase Overview

```
Phase 1 (Current)         Phase 2                  Phase 3                  Phase 4
─────────────────         ───────                  ───────                  ───────
VMware → AVS              DB → Azure SQL           App → Containers         Full PaaS
(lift & shift)            (data modernization)     (app modernization)      (cloud native)

┌───────────────┐    ┌───────────────┐    ┌───────────────┐    ┌───────────────┐
│ All VMs on    │    │ DB01 retired   │    │ APP01/02      │    │ WEB01/02      │
│ AVS           │───▶│ Azure SQL DB  │───▶│ → AKS / App   │───▶│ → Static Web  │
│               │    │ active        │    │   Service      │    │   Apps + CDN  │
│ WEB01, WEB02  │    │               │    │               │    │               │
│ APP01, APP02  │    │ WEB/APP still │    │ WEB still on  │    │ All PaaS      │
│ DB01          │    │ on AVS        │    │ AVS           │    │ AVS retired   │
└───────────────┘    └───────────────┘    └───────────────┘    └───────────────┘
     Est. Month 1         Month 3-4            Month 6-8           Month 10-12
```

### Phase 2 — Database Modernization (DB01 → Azure SQL)

| Task | Details |
|------|---------|
| Assessment | Run Azure Migrate / Data Migration Assistant (DMA) on DB01 |
| Schema migration | Export schema from SQL Server 2019 on DB01, import to Azure SQL |
| Data migration | Use Azure Database Migration Service (DMS) for online migration |
| Connection string update | Update APP01/APP02 config to point to `sql-harbor-retail.database.windows.net` |
| Cutover | Switch to Azure SQL, retire DB01 VM on AVS |
| Validation | Run application smoke tests, verify data integrity |

**Benefits:** Automated patching, built-in HA, geo-replication, cost savings (~40% vs. VM).

### Phase 3 — Application Modernization (APP01/APP02 → Azure App Service or AKS)

| Task | Details |
|------|---------|
| Containerize | Package .NET application from APP01/APP02 into Docker containers |
| Platform selection | Azure App Service (simpler) or AKS (more control) |
| Deploy | Push container images to Azure Container Registry (ACR) |
| Configure | App Service VNet integration or AKS with private endpoint |
| Traffic shift | Use Azure Front Door weighted routing for gradual cutover |
| Retire | Decommission APP01/APP02 VMs on AVS |

**Benefits:** Auto-scaling, deployment slots, managed infrastructure, CI/CD integration.

### Phase 4 — Web Tier Modernization (WEB01/WEB02 → Azure Static Web Apps)

| Task | Details |
|------|---------|
| Analyze | Determine if web tier is static content + API or server-rendered |
| If static | Deploy to Azure Static Web Apps with Azure CDN |
| If dynamic | Deploy to Azure App Service alongside the app tier |
| CDN | Azure Front Door already in place — add new origins |
| Retire | Decommission WEB01/WEB02 VMs, reduce AVS cluster |

**Benefits:** Global CDN, zero server management, free SSL, GitHub Actions integration.

---

## Cost Optimization Recommendations

### Immediate (Phase 1 — AVS)

| Recommendation | Estimated Savings | Effort |
|---------------|-------------------|--------|
| **Reserved Instances** — Commit to 1- or 3-year RI for AVS hosts | 30–50% on compute | Low |
| **Right-size AVS cluster** — Start with 3 hosts, scale only when metrics justify | Avoid over-provisioning | Low |
| **Azure Hybrid Benefit** — Apply existing Windows Server / SQL Server licenses | Up to 40% on licensing | Low |
| **Shut down dev/test workloads** — Use Azure Automation to stop non-prod VMs off-hours | 10–30% on non-prod | Medium |

### Medium-Term (Phase 2–3 — Modernization)

| Recommendation | Estimated Savings | Effort |
|---------------|-------------------|--------|
| **Azure SQL Serverless** — Use serverless tier for dev/test databases | Auto-pause saves ~60% idle cost | Low |
| **App Service B1/S1 tiers** — Start small, scale with traffic | Avoid Premium unless needed | Low |
| **Storage lifecycle policies** — Move cold blobs to Cool/Archive tiers | 50–70% on storage | Medium |
| **Azure Front Door caching** — Cache static assets at edge PoPs | Reduce origin load and bandwidth | Medium |

### Long-Term (Phase 4 — Full PaaS)

| Recommendation | Estimated Savings | Effort |
|---------------|-------------------|--------|
| **Decommission AVS** — Once all VMs are off AVS, release the private cloud | Eliminate ~$18K/mo (3 hosts) | High |
| **Azure Savings Plan** — Commit to 1- or 3-year compute savings plan | 15–30% across PaaS compute | Low |
| **Spot Instances for batch** — Use Spot VMs for non-critical batch jobs | Up to 90% on batch compute | Medium |
| **Azure Advisor** — Continuously review Advisor cost recommendations | Varies | Low |

### Monitoring Costs

- Enable **Microsoft Cost Management** budgets and alerts
- Create a cost dashboard in the **rg-harbor-retail-avs** resource group
- Review **Azure Advisor** recommendations weekly during migration
- Track per-phase costs to validate modernization ROI

---

## Appendix — Resource Naming Convention

| Resource Type | Naming Pattern | Example |
|--------------|----------------|---------|
| Resource Group | rg-{project}-{workload} | rg-harbor-retail-avs |
| Virtual Network | vnet-{project}-{purpose} | vnet-harbor-retail-transit |
| Subnet | snet-{purpose} | snet-private-endpoints |
| NSG | nsg-{project}-{purpose} | nsg-harbor-retail-pe |
| Private Endpoint | pe-{project}-{service} | pe-harbor-retail-sql |
| Private DNS Zone | privatelink.{service}.windows.net | privatelink.database.windows.net |
| SQL Server | sql-{project} | sql-harbor-retail |
| SQL Database | sqldb-{project} | sqldb-harbor-retail |
| Storage Account | st{project} (no hyphens) | stharborretail |
| Front Door | afd-{project} | afd-harbor-retail |
| Front Door Endpoint | fde-{project}-{tier} | fde-harbor-retail-web |
