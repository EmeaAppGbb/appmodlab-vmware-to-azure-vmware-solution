# Harbor Retail — VMware to AVS Assessment Report

**Date:** 2026-04-16
**Source vCenter:** vcenter.harbor.local (vSphere 7.0.3)
**Datacenter:** Harbor-DC01 | **Cluster:** Harbor-Production
**Assessment Scope:** Full environment — 5 VMs across 3 tiers

---

## 1. VM Inventory Summary

| VM | Role | OS | vCPU | RAM (GB) | Provisioned (GB) | Used (GB) | Host | Resource Pool |
|----|------|----|-----:|---------:|------------------:|----------:|------|---------------|
| WEB01 | IIS Web Server (LB) | Windows Server 2019 | 4 | 8 | 100 | 45 | esxi-host01 | Web-Pool |
| WEB02 | IIS Web Server (LB) | Windows Server 2019 | 4 | 8 | 100 | 43 | esxi-host02 | Web-Pool |
| APP01 | API Server | Windows Server 2019 | 8 | 16 | 200 | 120 | esxi-host01 | App-Pool |
| APP02 | API Server | Windows Server 2019 | 8 | 16 | 200 | 118 | esxi-host02 | App-Pool |
| DB01 | SQL Server 2019 Std | Windows Server 2019 | 16 | 64 | 500 | 320 | esxi-host03 | DB-Pool |

### Aggregate Totals

| Resource | Value |
|----------|------:|
| Total vCPUs | 40 |
| Total RAM | 112 GB |
| Total Provisioned Storage | 1,100 GB (1.07 TB) |
| Total Used Storage | 646 GB (0.63 TB) |
| VMware Tools Status | All running (`guestToolsRunning`) |

---

## 2. Network Topology Analysis

### NSX-V Configuration

- **NSX Version:** NSX-V 6.4.10 (end-of-life — AVS requires NSX-T)
- **VDS:** Harbor-VDS-01 (v7.0.0, MTU 1600, 512 ports)

### Logical Switches & VLANs

| Logical Switch | VNI | Subnet | Gateway | VLAN ID | Port Group | VMs |
|----------------|-----|--------|---------|--------:|------------|-----|
| LS-Web | 5001 | 10.10.10.0/24 | 10.10.10.1 | 10 | Web-Segment | WEB01, WEB02 |
| LS-App | 5002 | 10.10.20.0/24 | 10.10.20.1 | 20 | App-Segment | APP01, APP02 |
| LS-DB | 5003 | 10.10.30.0/24 | 10.10.30.1 | 30 | DB-Segment | DB01 |

### DRS Rules

| Rule | Type | VMs | Mandatory |
|------|------|-----|-----------|
| Web-Tier-Anti-Affinity | VmAntiAffinityRule | WEB01, WEB02 | Yes |
| App-Tier-Anti-Affinity | VmAntiAffinityRule | APP01, APP02 | Yes |

### HA Configuration

- HA Enabled with admission control
- VM monitoring: vmMonitoringOnly
- Host monitoring: enabled

---

## 3. HCX Compatibility Findings

| VM | HCX Ready | Notes |
|----|-----------|-------|
| WEB01 | ✅ Yes | VMware Tools running, no snapshots, single disk, single NIC |
| WEB02 | ✅ Yes | VMware Tools running, no snapshots, single disk, single NIC |
| APP01 | ✅ Yes | VMware Tools running, no snapshots, single disk, single NIC |
| APP02 | ✅ Yes | VMware Tools running, no snapshots, single disk, single NIC |
| DB01 | ⚠️ Yes (with caveats) | VMware Tools running, no snapshots, **2 virtual disks** (500 GB), 16 vCPU — largest VM; schedule during maintenance window |

### HCX Migration Method Recommendations

| VM | Recommended Method | Rationale |
|----|--------------------|-----------|
| WEB01, WEB02 | HCX vMotion | Small footprint (100 GB), zero downtime |
| APP01, APP02 | HCX vMotion | Medium footprint (200 GB), zero downtime |
| DB01 | HCX Bulk Migration | Large disk (500 GB, 2 disks); bulk migration provides checkpoint/resume; schedule during maintenance window for SQL quiesce |

### Pre-Migration Checklist

- [x] VMware Tools running on all VMs
- [x] No snapshots detected
- [x] vSphere 7.0.3 — fully supported by HCX
- [ ] Verify VMXNET3 adapter type on all VMs (recommended)
- [ ] Validate HCX appliance network connectivity (Management, vMotion, Uplink)
- [ ] Configure HCX Network Extension for L2 stretch during migration

---

## 4. Storage Analysis

### Per-VM Storage

| VM | Disks | Provisioned (GB) | Used (GB) | Utilization |
|----|------:|------------------:|----------:|------------:|
| WEB01 | 1 | 100 | 45 | 45% |
| WEB02 | 1 | 100 | 43 | 43% |
| APP01 | 1 | 200 | 120 | 60% |
| APP02 | 1 | 200 | 118 | 59% |
| DB01 | 2 | 500 | 320 | 64% |

### Storage Totals

| Metric | Value |
|--------|------:|
| Total Provisioned | 1,100 GB |
| Total Used | 646 GB |
| Overall Utilization | 58.7% |
| Total Virtual Disks | 6 |

### AVS vSAN Compatibility

- All VMDKs are well within the 62 TB vSAN maximum VMDK size
- Largest single VM storage footprint: 500 GB (DB01) — no issues
- Thick-provisioned disks will be automatically converted to vSAN objects
- **vSAN FTT=1 (RAID-1)** recommended: effective capacity is ~50% of raw storage

---

## 5. AVS Sizing Recommendation

### Recommended Configuration: 3× AV36 Nodes (Minimum Cluster)

#### AV36 Node Specifications

| Resource | Per Node | Per Node (Usable @ 25% HA Reserve) |
|----------|------:|------:|
| CPU Cores | 36 | 27 |
| Memory | 576 GB | 432 GB |
| Storage | 15.36 TB | 11.52 TB |

#### Sizing Calculation

| Dimension | Workload Demand | Usable Per Node | Nodes Required |
|-----------|----------------:|----------------:|---------------:|
| CPU | 40 vCPUs | 27 cores | 2 → **3 (minimum)** |
| Memory | 112 GB | 432 GB | 1 → **3 (minimum)** |
| Storage | 1.07 TB | 11.52 TB | 1 → **3 (minimum)** |

**Result: 3 AV36 nodes** — the AVS minimum cluster size satisfies all resource dimensions with significant headroom.

#### Capacity Headroom at 3 Nodes

| Resource | Total Usable (3 nodes) | Workload | Headroom |
|----------|----------:|----------:|---------:|
| CPU | 81 cores | 40 vCPUs | 50.6% free |
| Memory | 1,296 GB | 112 GB | 91.4% free |
| Storage | 34.56 TB | 1.07 TB | 96.9% free |

#### Alternative SKU Comparison

| SKU | Nodes Required | Notes |
|-----|---------------:|-------|
| AV36 | 3 | Cost-effective; ample headroom for this workload |
| AV36P | 3 | Higher memory (768 GB/node); consider if memory demand grows |
| AV52 | 3 | Premium tier; overkill for current workload |

> **Recommendation:** Start with **3× AV36 nodes** in a single cluster. This provides the minimum AVS cluster with N+1 HA protection and significant room for growth. Scale to AV36P only if future workloads demand >576 GB RAM per node.

---

## 6. Migration Risks and Mitigations

### Risk 1: NSX-V to NSX-T Network Migration

| Attribute | Detail |
|-----------|--------|
| **Risk Level** | 🟡 Medium |
| **Description** | The source environment runs NSX-V 6.4.10, which is end-of-life. AVS uses NSX-T natively. All 3 logical switches (LS-Web, LS-App, LS-DB) and associated firewall rules must be mapped to NSX-T segments. |
| **Impact** | Network misconfiguration could cause application downtime or connectivity loss between tiers. |
| **Mitigation** | 1. Use **HCX Network Extension** to stretch L2 segments from NSX-V to AVS during migration, preserving IP addresses and avoiding re-IP. |
| | 2. Map each NSX-V logical switch to a corresponding AVS NSX-T segment pre-migration. |
| | 3. Recreate NSX-V distributed firewall rules as NSX-T Gateway/Distributed Firewall policies. |
| | 4. After cutover, remove HCX L2 extensions and transition to native NSX-T routing. |
| | 5. Verify MTU consistency (source VDS: 1600; ensure AVS overlay matches). |

### Risk 2: Single SQL Server Instance (DB01)

| Attribute | Detail |
|-----------|--------|
| **Risk Level** | 🔴 High |
| **Description** | DB01 is the sole SQL Server 2019 Standard instance. It is tagged as `Critical` and holds all application data. There is no SQL Always On Availability Group or failover cluster. A migration failure or extended downtime directly impacts the entire application. |
| **Impact** | Data loss or extended outage if migration encounters errors; no built-in SQL-level HA for automatic failover. |
| **Mitigation** | 1. Take a **full SQL backup** (database + transaction log) immediately before migration. |
| | 2. Use **HCX Bulk Migration** with a scheduled maintenance window to allow SQL quiesce and consistency checks. |
| | 3. Validate SQL database integrity (`DBCC CHECKDB`) pre- and post-migration. |
| | 4. Prepare a tested **rollback plan** — restore from backup to source if migration fails. |
| | 5. Post-migration: evaluate SQL Always On or Azure SQL managed options for HA. |
| | 6. Migrate DB01 **last** after web and app tiers are validated on AVS. |

### Risk 3: Active Directory Dependency

| Attribute | Detail |
|-----------|--------|
| **Risk Level** | 🟡 Medium |
| **Description** | All 5 VMs are Windows Server 2019 domain-joined (harbor.local). The AD domain controller is not included in this VM inventory, implying it either resides outside the migration scope or is a shared infrastructure service. DNS resolution, authentication, and Group Policy depend on AD connectivity. |
| **Impact** | Post-migration VMs may lose domain authentication, DNS resolution, or GPO application if AD connectivity is disrupted during or after migration. |
| **Mitigation** | 1. Verify AD domain controller location — if on-premises, ensure **ExpressRoute** or **VPN connectivity** from AVS to AD is established before migration. |
| | 2. Configure **DNS forwarding** in AVS NSX-T to resolve harbor.local via the existing AD DNS servers. |
| | 3. If AD is on-premises, consider deploying a **read-only domain controller (RODC)** in AVS for local authentication. |
| | 4. Test domain join and GPO refresh from AVS network segments before migrating production VMs. |
| | 5. Ensure AVS NSX-T firewall rules permit LDAP (389/636), Kerberos (88), DNS (53), and SMB (445) to AD. |

### Risk 4: DRS Rule Recreation

| Attribute | Detail |
|-----------|--------|
| **Risk Level** | 🟢 Low |
| **Description** | Two mandatory anti-affinity DRS rules exist (Web-Tier, App-Tier). These must be manually recreated in the AVS vCenter cluster. |
| **Impact** | Without anti-affinity rules, paired VMs (WEB01/WEB02, APP01/APP02) could land on the same host, reducing resilience. |
| **Mitigation** | 1. Document existing DRS rules (captured above). |
| | 2. Recreate anti-affinity rules in AVS vCenter post-migration. |
| | 3. Validate placement after first DRS cycle. |

### Risk 5: Resource Pool Configuration

| Attribute | Detail |
|-----------|--------|
| **Risk Level** | 🟢 Low |
| **Description** | Three resource pools (Web-Pool, App-Pool, DB-Pool) with CPU/memory reservations need to be recreated in AVS. |
| **Impact** | Without reservations, the DB tier could be starved of resources during contention. |
| **Mitigation** | 1. Recreate resource pools in AVS vCenter with matching reservation values. |
| | 2. DB-Pool: 16,000 MHz CPU reservation, 65,536 MB memory reservation. |
| | 3. App-Pool: 8,000 MHz CPU, 32,768 MB memory (high shares). |
| | 4. Web-Pool: 4,000 MHz CPU, 16,384 MB memory (normal shares). |

---

## Summary

| Area | Status | Notes |
|------|--------|-------|
| VM Compatibility | ✅ Pass | All 5 VMs meet HCX requirements |
| Network | ⚠️ Remediation | NSX-V → NSX-T segment mapping required |
| Storage | ✅ Pass | 1,100 GB provisioned; well within vSAN limits |
| AVS Sizing | ✅ 3× AV36 | Minimum cluster with ample headroom |
| DRS/HA | ⚠️ Remediation | 2 anti-affinity rules to recreate |
| SQL Server | ⚠️ Risk | Single instance; backup + maintenance window required |
| Active Directory | ⚠️ Risk | Verify connectivity from AVS to AD domain |

**Overall Readiness: Ready with Remediation**
