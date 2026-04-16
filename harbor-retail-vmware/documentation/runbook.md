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

### Pre-requisites

**Firewall Ports** — Ensure the following ports are open between on-premises and AVS:

| Port | Protocol | Direction | Purpose |
|------|----------|-----------|---------|
| 443 | TCP | Bidirectional | HCX Manager REST API and web UI |
| 8443 | TCP | Outbound | HCX bulk migration and replication traffic |
| 9443 | TCP | Outbound | HCX vMotion traffic |
| 4500 | UDP | Bidirectional | IPsec NAT-T tunnel encapsulation |
| 500 | UDP | Bidirectional | IPsec ISAKMP key exchange |

**Software Requirements:**
- PowerShell 5.1+
- VMware PowerCLI 13.0+
- Azure CLI 2.50+ (logged in with `az login`)
- HCX Connector OVA (downloaded automatically or pre-staged)

**Network Requirements:**
- Management network: 10.10.0.0/24 (VLAN 10) — minimum 20 IPs for HCX appliances
- vMotion network: 10.10.40.0/24 (VLAN 40) — MTU 9000 recommended
- Uplink network: 10.10.50.0/24 (VLAN 50) — WAN-facing for tunnel traffic

### Automated Setup (Recommended)

Run the full HCX configuration in simulation mode first, then live:

```powershell
# Simulation mode — validates workflow without external connections
.\scripts\powercli\configure-hcx.ps1 `
    -VCenterServer vcenter.harbor.local `
    -AVSPrivateCloudName Harbor-AVS-PrivateCloud `
    -AVSResourceGroup Harbor-AVS-RG `
    -Simulate

# Live mode — performs actual HCX setup
.\scripts\powercli\configure-hcx.ps1 `
    -VCenterServer vcenter.harbor.local `
    -AVSPrivateCloudName Harbor-AVS-PrivateCloud `
    -AVSResourceGroup Harbor-AVS-RG `
    -HCXActivationKey "XXXXX-XXXXX-XXXXX" `
    -AVSHCXCloudManagerUrl hcx-cloud.avs.azure.com `
    -Credential (Get-Credential)
```

The script outputs a detailed JSON report to `.\output\hcx-setup-report.json`.

### Step-by-Step Manual Instructions

If you prefer manual setup or need to troubleshoot individual steps:

#### Step 3.1: Activate HCX on AVS Private Cloud

```bash
az vmware addon hcx create \
  --resource-group Harbor-AVS-RG \
  --private-cloud Harbor-AVS-PrivateCloud \
  --offer "VMware MaaS Cloud Provider"
```

Verify activation status:
```bash
az vmware addon hcx show \
  --resource-group Harbor-AVS-RG \
  --private-cloud Harbor-AVS-PrivateCloud \
  --query "provisioningState" -o tsv
```

**Expected:** `Succeeded` (may take 10-15 minutes)

#### Step 3.2: Deploy HCX Connector OVA On-Premises

1. Download the HCX Connector OVA from the AVS portal (Azure Portal → AVS Private Cloud → Manage → Add-ons → HCX)
2. Deploy the OVA to on-premises vCenter:
   - Target host: Any ESXi host in the Harbor-Production cluster
   - Datastore: vsanDatastore (requires ~12 GB)
   - Network: HCX-Management-PortGroup (10.10.0.0/24)
3. Power on the HCX Connector VM
4. Access the HCX Manager UI at `https://<connector-ip>:443`
5. Activate with the license key obtained from the AVS portal

#### Step 3.3: Configure Site Pairing

1. Log in to HCX Manager at `https://hcx-connector.harbor.local`
2. Navigate to **Infrastructure → Site Pairing → Add Site Pairing**
3. Enter the AVS HCX Cloud Manager URL: `https://hcx-cloud.avs.azure.com`
4. Provide AVS vCenter credentials (obtain from Azure Portal → AVS → Identity)
5. Accept the certificate and complete pairing

**Validation:** Both sites should show status **Connected** in the Site Pairing dashboard.

#### Step 3.4: Create Network Profiles

Network profile definitions are stored in `scripts/powercli/hcx-network-profiles.json`.

Create three network profiles in HCX Manager → **Infrastructure → Network Profiles**:

| Profile | Network | CIDR | IP Pool | MTU | VLAN |
|---------|---------|------|---------|-----|------|
| HCX-Management-NetworkProfile | HCX-Management-PortGroup | 10.10.0.0/24 | 10.10.0.10–10.10.0.30 | 1500 | 10 |
| HCX-vMotion-NetworkProfile | HCX-vMotion-PortGroup | 10.10.40.0/24 | 10.10.40.10–10.10.40.30 | 9000 | 40 |
| HCX-Uplink-NetworkProfile | HCX-Uplink-PortGroup | 10.10.50.0/24 | 10.10.50.10–10.10.50.30 | 1500 | 50 |

DNS for all profiles: Primary 10.10.0.2, Secondary 10.10.0.3, Search domain: harbor.local

#### Step 3.5: Create Compute Profiles

Create two compute profiles in HCX Manager → **Infrastructure → Compute Profiles**:

**Source (On-Premises):**
- Name: `Harbor-OnPrem-ComputeProfile`
- Cluster: Harbor-Production
- Datastore: vsanDatastore
- Services: Interconnect, vMotion, Bulk Migration, Network Extension, Disaster Recovery

**Destination (AVS):**
- Name: `Harbor-AVS-ComputeProfile`
- Cluster: Cluster-1
- Datastore: vsanDatastore
- Services: Interconnect, vMotion, Bulk Migration, Network Extension, Disaster Recovery

#### Step 3.6: Deploy Service Mesh

1. Navigate to **Infrastructure → Service Mesh → Create Service Mesh**
2. Select source compute profile: `Harbor-OnPrem-ComputeProfile`
3. Select destination compute profile: `Harbor-AVS-ComputeProfile`
4. Select services: Interconnect, vMotion, Bulk Migration, Network Extension
5. Assign network profiles (management, vMotion, uplink)
6. Review topology and click **Finish**

**Expected duration:** 15-20 minutes for appliance deployment and tunnel establishment.

#### Step 3.7: Validate Tunnel Status

Verify all tunnels are operational in HCX Manager → **Infrastructure → Service Mesh → Dashboard**:

- **Interconnect tunnel:** Status UP
- **vMotion reachability:** Status OK
- **Network Extension:** Status UP

### Troubleshooting

| Symptom | Likely Cause | Resolution |
|---------|-------------|------------|
| Site pairing fails with timeout | Port 443 blocked between on-prem and AVS | Verify firewall rules allow TCP 443 bidirectionally |
| Service mesh deployment stuck | Port 8443/9443 not open | Open TCP 8443 and 9443 outbound to AVS |
| Tunnel status shows DOWN | IPsec ports blocked | Ensure UDP 500 and 4500 are open bidirectionally |
| vMotion migration fails | vMotion network MTU mismatch | Set MTU to 9000 on both ends of vMotion network |
| HCX Connector activation fails | Invalid or expired license key | Regenerate the activation key from the AVS portal |
| Network profile creation fails | IP pool conflicts | Verify no overlapping IPs with existing DHCP or static assignments |
| "Certificate not trusted" error | Self-signed cert on HCX Manager | Accept the certificate or import AVS CA cert into trust store |

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
