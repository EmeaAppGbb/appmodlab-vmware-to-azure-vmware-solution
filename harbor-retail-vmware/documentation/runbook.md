# Harbor Retail VMware to AVS Migration Runbook

## Overview
Migration of Harbor Retail Group's 5-VM VMware environment to Azure VMware Solution using HCX.

## Migration Waves
- **Wave 1:** WEB01, WEB02 (Zero downtime via HCX vMotion)
- **Wave 2:** APP01, APP02 (Zero downtime via HCX vMotion)  
- **Wave 3:** DB01 (Minimal downtime via HCX Bulk Migration)

## Phase 1: Assessment (1-2 hours)

### Export Inventory
```powershell
.\scripts\powercli\export-inventory.ps1 -vCenterServer vcenter.harbor.local -OutputPath .\exports
```

### Run Compatibility Assessment
```powershell
.\scripts\powercli\assess-compatibility.ps1 -vCenterServer vcenter.harbor.local
```

**Expected Results:**
- 5 VMs compatible
- Recommended: 3x AV36 nodes
- No blockers

## Phase 2: AVS Provisioning (3-4 hours)

### Deploy AVS Private Cloud
```bash
az vmware private-cloud create \
  --resource-group Harbor-AVS-RG \
  --name Harbor-AVS-PrivateCloud \
  --location eastus \
  --cluster-size 3 \
  --network-block 10.175.0.0/22 \
  --sku AV36
```

### Configure NSX-T Segments
```bash
az vmware workload-network segment create \
  --resource-group Harbor-AVS-RG \
  --private-cloud Harbor-AVS-PrivateCloud \
  --segment Web-Segment \
  --gateway-address 10.10.10.1/24
```

Repeat for App-Segment (10.10.20.1/24) and DB-Segment (10.10.30.1/24).

## Phase 3: HCX Setup (1-2 hours)

1. Download HCX OVA from AVS portal
2. Deploy HCX Manager to on-premises vCenter
3. Configure site pairing with AVS HCX Cloud Manager
4. Create network and compute profiles
5. Deploy service mesh with vMotion and bulk migration services

## Phase 4: Migration Execution (2-3 hours)

### Wave 1: Web Tier
```powershell
.\scripts\powercli\migration-runbook.ps1 -Wave 1 -MigrationType vMotion
```

**Duration:** ~30 minutes  
**Validation:** Test https://portal.harbor.local

### Wave 2: Application Tier
```powershell
.\scripts\powercli\migration-runbook.ps1 -Wave 2 -MigrationType vMotion
```

**Duration:** ~45 minutes  
**Validation:** Test API endpoints

### Wave 3: Database Tier
```powershell
.\scripts\powercli\migration-runbook.ps1 -Wave 3 -MigrationType BulkMigration
```

**Duration:** ~2 hours  
**Validation:** DBCC CHECKDB, application end-to-end test

## Phase 5: Post-Migration (1-2 hours)

### Configure NSX-T Firewall Rules
```bash
# Allow Web to App
az vmware workload-network gateway firewall-rule create \
  --rule-name Allow-Web-to-App \
  --source-addresses 10.10.10.0/24 \
  --destination-addresses 10.10.20.0/24 \
  --destination-ports 443,80 \
  --protocols TCP \
  --action ALLOW
```

### Enable Azure Backup
```bash
az backup protection enable-for-vm \
  --vault-name Harbor-AVS-Backup-Vault \
  --policy-name DefaultPolicy
```

## Success Criteria
- [ ] All 5 VMs migrated and powered on in AVS
- [ ] Application fully functional
- [ ] Performance within 10% of baseline
- [ ] NSX-T firewall rules applied
- [ ] Azure Backup configured
- [ ] Azure Monitor enabled
