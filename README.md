# 🌌 VMware to Azure VMware Solution Migration Lab 🚀

```
╔═══════════════════════════════════════════════════════════════════╗
║                                                                   ║
║   ██╗   ██╗███╗   ███╗██╗    ██╗ █████╗ ██████╗ ███████╗         ║
║   ██║   ██║████╗ ████║██║    ██║██╔══██╗██╔══██╗██╔════╝         ║
║   ██║   ██║██╔████╔██║██║ █╗ ██║███████║██████╔╝█████╗           ║
║   ╚██╗ ██╔╝██║╚██╔╝██║██║███╗██║██╔══██║██╔══██╗██╔══╝           ║
║    ╚████╔╝ ██║ ╚═╝ ██║╚███╔███╔╝██║  ██║██║  ██║███████╗         ║
║     ╚═══╝  ╚═╝     ╚═╝ ╚══╝╚══╝ ╚═╝  ╚═╝╚═╝  ╚═╝╚══════╝         ║
║                                                                   ║
║              🛸 WARP JUMP TO THE AZURE GALAXY 🛸                  ║
║                                                                   ║
╚═══════════════════════════════════════════════════════════════════╝
```

## 🎮 MISSION BRIEFING

Welcome, Cloud Commander! 👨‍🚀👩‍🚀

Your mission: Guide the **Harbor Retail Group's** fleet of virtual machines through a warp jump from their on-premises VMware data center to the **Azure VMware Solution (AVS)** galaxy! This isn't just any migration—it's a **LIVE MIGRATION** with zero downtime, powered by the legendary **VMware HCX** warp drive! ✨

## 🌟 THE JOURNEY AHEAD

Transform your legacy VMware infrastructure into a cloud-native hybrid powerhouse:

```
ON-PREMISES VCENTER          HCX WARP TUNNEL           AZURE VMware SOLUTION
     🏢                    ═════════════════►                ☁️
  [5 VMs Ready]              LIGHT-SPEED                [Cloud Native]
  [NSX-V Legacy]             MIGRATION                  [NSX-T Modern]
  [vSAN Storage]             🚀 ✨ 🌌                   [Azure Integrated]
```

### 🎯 VICTORY CONDITIONS

- ✅ **VCENTER SCANNED** 🔍 — Inventory assessed, compatibility verified
- ✅ **AVS DEPLOYED** 🌐 — Private cloud provisioned in Azure
- ✅ **HCX ACTIVATED** 🛸 — Warp drive deployed and site paired
- ✅ **LIVE MIGRATION** ✈️ — VMs warped with ZERO downtime
- ✅ **NSX-T CONFIGURED** 🔐 — Security shields upgraded
- ✅ **AZURE CONNECTED** 🔌 — ExpressRoute link established
- ✅ **BACKUP ONLINE** 💾 — Azure Backup protecting your fleet
- ✅ **MONITORING ACTIVE** 📊 — Azure Monitor tracking all systems

## 🚀 THE FLEET MANIFEST

### Harbor Retail Group's Virtual Armada

| Vessel ID | OS Platform | Mission Role | vCPU | RAM | Storage | Network Sector |
|-----------|-------------|--------------|------|-----|---------|----------------|
| 🌐 WEB01 | Windows 2019 | IIS Web Server | 4 | 8 GB | 100 GB | Web-Segment |
| 🌐 WEB02 | Windows 2019 | IIS Web Server | 4 | 8 GB | 100 GB | Web-Segment |
| ⚙️ APP01 | Windows 2019 | API Server | 8 | 16 GB | 200 GB | App-Segment |
| ⚙️ APP02 | Windows 2019 | API Server | 8 | 16 GB | 200 GB | App-Segment |
| 🗄️ DB01 | Windows 2019 | SQL Server 2019 | 16 | 64 GB | 500 GB | DB-Segment |

**Total Fleet Power:** 40 vCPUs • 112 GB RAM • 900 GB Storage 💪

## 🎯 LEARNING OBJECTIVES

By completing this mission, you'll master:

- 🔍 **Reconnaissance** — Assess VMware environments for AVS compatibility
- 🏗️ **Base Construction** — Provision and configure an AVS private cloud
- 🛸 **Warp Technology** — Set up VMware HCX for workload migration
- ✈️ **Live Transport** — Migrate VMs with minimal/zero downtime
- 🌐 **Network Mastery** — Configure NSX-T networking and micro-segmentation
- 🔌 **Hybrid Integration** — Connect AVS to Azure native services via ExpressRoute
- 💾 **Data Protection** — Configure Azure Backup for cloud VMs
- 📊 **Observability** — Set up Azure Monitor for fleet tracking

## 🎮 TECH STACK ARSENAL

### 🏢 Legacy Systems (On-Premises)
- 🔧 VMware vSphere 7.0 with vCenter Server
- 🌐 NSX-V for network virtualization (legacy shields)
- 💾 vSAN for shared storage
- 🖥️ Windows Server 2019 (Web/App tiers)
- 🗄️ SQL Server 2019 Standard
- 🌐 ASP.NET MVC application on IIS
- 🔐 Active Directory domain-joined VMs
- ⚡ vSphere HA + DRS enabled
- 🚀 vMotion for live VM migration

### ☁️ Target Platform (Azure)
- 🌌 **Azure VMware Solution (AVS)** — Native VMware in Azure
- 🛸 **VMware HCX** — Warp drive for migration
- 🔐 **NSX-T** — Next-gen network virtualization
- 💾 **vSAN on AVS** — Cloud storage policies
- ⚡ **ExpressRoute Global Reach** — High-speed connectivity
- 🔐 **Azure AD + AD DS** — Identity federation
- 💾 **Azure Backup** — Cloud-native protection
- 📊 **Azure Monitor** — Unified observability
- 🌐 **Azure Private DNS** — Name resolution

## 📋 PRE-FLIGHT CHECKLIST

Before starting your warp jump, ensure you have:

- ✅ VMware vSphere administration experience
- ✅ Azure subscription with **AVS quota approved** (⚠️ requires quota request!)
- ✅ Azure CLI and PowerCLI installed
- ✅ Basic networking knowledge (BGP, ExpressRoute)
- ✅ VMware HCX license (included with AVS)
- ✅ Coffee ☕ (6-8 hour mission + 3-4 hour AVS provisioning time)

## 🗺️ MISSION PHASES

### 🌟 PHASE 1: RECONNAISSANCE 🔍
**VCENTER SCANNED** — Discover your fleet

- Export vCenter inventory with PowerCLI
- Check HCX compatibility matrix
- Document network topology and dependencies
- Identify migration waves by application tier
- Baseline performance metrics

**Branch:** `step-1-assessment`

---

### 🌟 PHASE 2: ESTABLISH BASE 🏗️
**AVS DEPLOYED** — Build your cloud fortress

- Provision AVS private cloud via Bicep/Terraform
- Configure management network
- Set up ExpressRoute connectivity
- Deploy VNet gateway for hybrid connection
- Verify AVS cluster health

**Branch:** `step-2-avs-provision`

**⏱️ WARNING:** AVS provisioning takes 3-4 hours! ⏳

---

### 🌟 PHASE 3: ACTIVATE WARP DRIVE 🛸
**HCX DEPLOYED** — Engage migration engine

- Deploy HCX connector in AVS
- Install HCX on-premises appliance
- Configure site pairing
- Create network profiles
- Set up service mesh
- Establish HCX tunnel

**Branch:** `step-3-hcx-setup`

---

### 🌟 PHASE 4: WARP JUMP 🚀
**LIVE MIGRATION** — Transport your fleet

- Plan migration waves (DB → App → Web)
- Configure replication for bulk migration
- Execute vMotion for zero-downtime migration
- Monitor migration progress
- Validate VM power-on in AVS
- Verify application connectivity

**Branch:** `step-4-migration`

**Migration Methods:**
- 🚀 **vMotion** — Zero downtime, live migration (best for production)
- 📦 **Bulk Migration** — Scheduled replication (for non-critical VMs)
- ❄️ **Cold Migration** — Powered-off transfer (fastest)
- ☁️ **Cloud Motion with vMotion** — Cross-cloud live migration

---

### 🌟 PHASE 5: ESTABLISH PERIMETER 🔐
**NSX-T CONFIGURED** — Upgrade security shields

- Create NSX-T segments (Web/App/DB)
- Migrate NSX-V firewall rules to NSX-T distributed firewall
- Configure micro-segmentation policies
- Set up NSX-T load balancer
- Configure DNS resolution
- Validate east-west traffic

**Branch:** `step-5-post-migration`

---

### 🌟 PHASE 6: AZURE INTEGRATION 🔌
**AZURE CONNECTED** — Join the Azure galaxy

- Configure ExpressRoute Global Reach
- Set up Azure Private DNS zones
- Connect to Azure native services:
  - 🗄️ Azure SQL Database (future modernization path)
  - 💾 Azure Storage (backup targets)
  - 🔐 Azure Key Vault (secrets management)
  - 📊 Azure Monitor (centralized logging)
- Configure Azure Backup for AVS VMs
- Set up Azure Monitor alerts

**Branch:** `step-5-post-migration`

---

## 📂 CARGO BAY STRUCTURE

Your mission repository contains:

```
harbor-retail-vmware/
├── 🔧 vmware-config/              # vCenter inventory & configuration
│   ├── vcenter-inventory.json     # VM fleet manifest
│   ├── network-topology.json      # Network map
│   ├── resource-pools.json        # Resource allocation
│   ├── drs-rules.json             # DRS policies
│   └── ha-config.json             # HA cluster config
│
├── 🖥️ vm-specs/                   # Virtual machine specifications
│   ├── web-tier/                  # Web servers (WEB01, WEB02)
│   ├── app-tier/                  # API servers (APP01, APP02)
│   └── db-tier/                   # Database (DB01)
│
├── 💻 application/                 # Harbor Retail application
│   ├── HarborRetail.Web/          # ASP.NET MVC frontend
│   ├── HarborRetail.Api/          # Web API business logic
│   └── HarborRetail.Database/     # SQL Server database project
│
├── 🌐 networking/                  # Network configuration
│   ├── nsx-v-config/              # Legacy NSX-V rules
│   ├── load-balancer/             # Load balancer config
│   └── dns-records.json           # DNS entries
│
├── 📜 scripts/                     # Automation arsenal
│   ├── powercli/                  # PowerCLI scripts
│   │   ├── export-inventory.ps1   # Inventory export
│   │   ├── assess-compatibility.ps1  # HCX compatibility check
│   │   └── migration-runbook.ps1  # Migration automation
│   └── terraform/                 # Infrastructure as Code
│       └── avs-provision.tf       # AVS deployment
│
└── 📚 documentation/               # Mission guides
    ├── runbook.md                 # Migration runbook
    └── rollback-plan.md           # Emergency procedures
```

## 🔀 NAVIGATION BRANCHES

Your mission timeline across Git branches:

```
🌳 BRANCH STRUCTURE
│
├─ 📘 main                    ─── Complete lab + APPMODLAB.md
│
├─ 🏢 legacy                  ─── VMware config exports + PowerCLI scripts
│
├─ ✅ solution                ─── AVS deployment + HCX + NSX-T (final state)
│
├─ 🔍 step-1-assessment       ─── Compatibility check + migration planning
│
├─ 🏗️ step-2-avs-provision    ─── AVS private cloud + networking
│
├─ 🛸 step-3-hcx-setup        ─── HCX connector + site pairing
│
├─ 🚀 step-4-migration        ─── VM migration waves with HCX
│
└─ 🔐 step-5-post-migration   ─── NSX-T policies + Azure integration
```

## ⚠️ KNOWN HAZARDS & OBSTACLES

### 🚨 Legacy System Challenges

- ❌ **NSX-V Deprecated** — Must migrate to NSX-T on AVS
- ❌ **Custom DRS Rules** — May not translate directly to AVS
- ❌ **vSAN Policies** — Need mapping to AVS storage policies
- ❌ **Network Micro-Segmentation** — NSX-V rules require NSX-T equivalents
- ❌ **Single SQL Instance** — No Always On (potential future enhancement)
- ❌ **Manual Scaling** — No auto-scaling configured
- ❌ **On-Prem Backup** — Needs migration to Azure Backup
- ❌ **No Azure Connectivity** — Requires ExpressRoute setup
- ❌ **Undocumented Baselines** — Performance metrics not tracked

### 💡 SURVIVAL TIPS

- 🕐 Start AVS provisioning early (3-4 hours!)
- 📋 Export complete inventory before starting
- 🧪 Test migration with non-critical VMs first
- 📊 Baseline application performance before/after
- 🔄 Plan rollback procedures for each phase
- 💾 Verify backups before decommissioning on-prem
- 🌐 Document all NSX-T policy changes
- 📞 Keep VMware and Azure support contacts handy

## ⏱️ MISSION DURATION

```
┌─────────────────────────────────────────────┐
│ Phase 1: Assessment           │ 1-2 hours  │
│ Phase 2: AVS Provisioning     │ 3-4 hours  │ ⏳ (automated wait)
│ Phase 3: HCX Setup            │ 1-2 hours  │
│ Phase 4: Migration            │ 2-3 hours  │
│ Phase 5: NSX-T Configuration  │ 1-2 hours  │
│ Phase 6: Azure Integration    │ 1-2 hours  │
├─────────────────────────────────────────────┤
│ TOTAL MISSION TIME            │ 9-15 hours │
└─────────────────────────────────────────────┘
```

**💡 PRO TIP:** Run AVS provisioning overnight! ☕🌙

## 🎓 KEY CONCEPTS MASTERED

By completing this lab, you'll understand:

- 🏗️ **Azure VMware Solution Architecture** — Running native VMware on Azure
- 🛸 **VMware HCX Migration Methods** — vMotion, bulk, cold, cloud motion
- 🔐 **NSX-T Networking** — Modern micro-segmentation on AVS
- ⚡ **ExpressRoute Global Reach** — High-speed hybrid connectivity
- 🔌 **Hybrid Cloud Integration** — Connecting AVS to Azure native services
- 💾 **Cloud Backup Strategies** — Azure Backup for VMware workloads
- 📊 **Unified Monitoring** — Azure Monitor for hybrid environments
- 🔄 **Migration Planning** — Wave-based migration strategies

## 🏆 ACHIEVEMENT UNLOCKED: AVS MIGRATION MASTER

Upon completing this lab, you'll have:

- ✨ Migrated a multi-tier application with **ZERO DOWNTIME**
- 🛸 Mastered **VMware HCX** warp drive technology
- 🔐 Upgraded from **NSX-V** to **NSX-T** security
- ⚡ Established **hybrid connectivity** to Azure
- 💾 Configured **cloud-native backup** and monitoring
- 🌌 Positioned Harbor Retail for **gradual modernization**

## 🆘 COMMUNICATIONS CHANNEL

- 📚 **Full Lab Guide:** See `APPMODLAB.md` for detailed walkthrough
- 🐛 **Report Issues:** GitHub Issues in this repository
- 💬 **Discuss:** GitHub Discussions for Q&A
- 📖 **Official Docs:** [Azure VMware Solution Documentation](https://docs.microsoft.com/azure/azure-vmware/)
- 🎓 **Learn More:** [VMware HCX Documentation](https://docs.vmware.com/en/VMware-HCX/)

## 📜 LICENSE

This lab is part of the App Modernization Labs collection.  
See the main repository for licensing information.

---

```
╔══════════════════════════════════════════════════════════════╗
║                                                              ║
║         🌌 READY FOR WARP JUMP, COMMANDER? 🌌               ║
║                                                              ║
║              git checkout step-1-assessment                  ║
║                                                              ║
║           🚀 LET THE MIGRATION BEGIN! 🚀                    ║
║                                                              ║
╚══════════════════════════════════════════════════════════════╝
```

**May your VMs migrate swiftly and your downtime be zero!** ✨🛸✨

---

*Built with 💜 by the Azure Global Black Belt team • EMEA App Modernization*
