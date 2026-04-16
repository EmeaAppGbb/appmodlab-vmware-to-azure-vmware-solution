# Harbor Retail — Migration Wave Plan

## Executive Summary

This document defines the three-wave migration strategy for moving the Harbor Retail
five-VM environment from on-premises VMware vSphere 7.0 to Azure VMware Solution (AVS)
using VMware HCX. The wave order is **DB → App → Web**, migrating the most critical
tier first to validate the platform end-to-end before moving dependent workloads.

| Wave | Tier | VMs | Method | Est. Duration | Maintenance Window |
|------|------|-----|--------|---------------|--------------------|
| 1 | Database | DB01 | HCX Bulk Migration | 2 hours | Saturday 22:00–02:00 |
| 2 | Application | APP01, APP02 | HCX vMotion | 1.5 hours | Sunday 00:00–02:00 |
| 3 | Web | WEB01, WEB02 | HCX vMotion | 1 hour | Sunday 02:00–04:00 |

**Total estimated window:** 6 hours (Saturday 22:00 – Sunday 04:00)

---

## Timeline Diagram

```
Saturday                                                       Sunday
22:00    23:00    00:00    01:00    02:00    03:00    04:00
  |--------|--------|--------|--------|--------|--------|
  [=== Wave 1: DB01 ===]                                       ← Bulk Migration
  |  Pre   | Migrate | Post  |
  |        |         | Valid.|
                     [==== Wave 2: APP01, APP02 ====]           ← vMotion
                     | Pre   | Migrate (parallel) | Post |
                                       [==== Wave 3: WEB01, WEB02 ====]  ← vMotion
                                       | Pre  | Migrate | Post | LB Cut |
  ──────────────────────────────────────────────────────────────
  ▲ Change freeze    ▲ Go/No-Go #1     ▲ Go/No-Go #2   ▲ All-clear
```

---

## Communication Plan

| When | Who | Channel | Message |
|------|-----|---------|---------|
| T-7 days | Migration Lead → All Stakeholders | Email + Teams | Maintenance window announced |
| T-2 days | Migration Lead → CAB | Change Advisory Board | Change request approved |
| T-1 day | Migration Lead → App Owners | Teams | Final confirmation & contacts |
| T-0 (22:00) | Migration Lead → War Room | Teams Bridge | Migration started – change freeze in effect |
| Wave 1 complete | Migration Lead → DBA Team | Teams Bridge | DB01 on AVS – validate applications |
| Wave 2 complete | Migration Lead → Dev Team | Teams Bridge | APP tier on AVS – validate API |
| Wave 3 complete | Migration Lead → All | Teams Bridge | Web tier on AVS – LB cutover done |
| T+1 hour | Migration Lead → All Stakeholders | Email | Migration complete – monitoring period |
| T+24 hours | Migration Lead → Management | Email | Post-migration report |

### Escalation Contacts

| Role | Name | Phone | Escalation |
|------|------|-------|------------|
| Migration Lead | TBD | TBD | Primary decision-maker |
| VMware / HCX Engineer | TBD | TBD | HCX migration issues |
| Network Engineer | TBD | TBD | Connectivity / DNS / LB |
| DBA | TBD | TBD | SQL Server issues |
| Application Owner | TBD | TBD | Functional validation |
| Microsoft AVS Support | N/A | Azure Support Ticket | AVS platform issues |

---

## Wave 1 — Database Tier (DB01)

**Rationale:** Migrate the database first to validate AVS storage performance, network
latency, and HCX data replication for the largest and most I/O-intensive workload.
Success here de-risks all subsequent waves.

### VM Details

| Property | Value |
|----------|-------|
| VM Name | DB01 |
| Guest OS | Windows Server 2019 |
| vCPU / RAM | 16 vCPU / 64 GB |
| Disks | 2 (500 GB provisioned, 320 GB used) |
| Network | DB-Segment (10.10.30.11) |
| Application | SQL Server 2019 Standard |
| Tags | Production, Database, Critical |
| Migration Method | HCX Bulk Migration (warm cutover) |

### Pre-Migration Checklist

- [ ] Run `validate-pre-migration.ps1 -VMName DB01` — all checks PASS
- [ ] Full SQL Server backup completed and verified (backup to on-prem + Azure Blob)
- [ ] Transaction log backup within last 15 minutes
- [ ] Verify no active SQL Agent jobs running
- [ ] Confirm no open transactions (`DBCC OPENTRAN`)
- [ ] VMware Tools running and current
- [ ] No active snapshots on DB01
- [ ] No CD/DVD or ISO mounted
- [ ] DNS forward and reverse lookup for `db01.harbor.local` → `10.10.30.11`
- [ ] Network connectivity from source to AVS DB-Segment validated
- [ ] Application teams notified of read-only / brief-outage window
- [ ] Monitoring dashboards open (CPU, memory, disk I/O, SQL wait stats)

### Migration Steps

1. **Set SQL Server to read-only** — Notify app tier; quiesce writes.
2. **Start HCX Bulk Migration** — Initiate replication for DB01.
3. **Monitor replication progress** — Wait for initial sync to complete.
4. **Schedule cutover** — Trigger switchover during maintenance window.
5. **Validate cutover** — Confirm DB01 powered on at AVS, IP retained.
6. **Restore read-write mode** — Set SQL Server back to read-write.
7. **Run post-migration validation** (see below).

### Estimated Duration

| Phase | Duration |
|-------|----------|
| Pre-checks & preparation | 15 min |
| HCX Bulk Migration (sync + cutover) | 60–90 min |
| Post-migration validation | 15 min |
| Buffer | 15 min |
| **Total** | **~2 hours** |

### Success Validation

- [ ] DB01 powered on in AVS vCenter
- [ ] IP address `10.10.30.11` reachable from App-Segment (ping + SQL port 1433)
- [ ] SQL Server service running (`Get-Service MSSQLSERVER`)
- [ ] `SELECT @@SERVERNAME` returns expected hostname
- [ ] Application database accessible: `SELECT COUNT(*) FROM [HarborRetail].[dbo].[Products]`
- [ ] SQL Agent jobs enabled and next schedule correct
- [ ] No errors in SQL Server error log post-migration
- [ ] Disk I/O latency within 20% of baseline

### Rollback Criteria

Trigger rollback if **any** of:
- DB01 does not power on within 15 minutes of cutover
- SQL Server service fails to start after 3 restart attempts
- Data integrity check fails (`DBCC CHECKDB`)
- Network connectivity to App tier not established within 10 minutes
- Query performance >50% worse than baseline after 30-minute soak

**Rollback procedure:** Restore from pre-migration full backup on source SQL Server.
Verify transaction log chain. Update DNS if any records changed.

### Dependencies

- None (first wave)

---

## Wave 2 — Application Tier (APP01, APP02)

**Rationale:** With the database confirmed healthy on AVS, migrate the API servers next.
These connect to DB01 (now on AVS) and serve the web tier. Anti-affinity rules ensure
APP01 and APP02 land on separate ESXi hosts in the AVS cluster.

### VM Details

| Property | APP01 | APP02 |
|----------|-------|-------|
| Guest OS | Windows Server 2019 | Windows Server 2019 |
| vCPU / RAM | 8 vCPU / 16 GB | 8 vCPU / 16 GB |
| Disks | 1 (200 GB / 120 GB used) | 1 (200 GB / 118 GB used) |
| Network | App-Segment (10.10.20.11) | App-Segment (10.10.20.12) |
| Application | Harbor Retail API | Harbor Retail API |
| Migration Method | HCX vMotion | HCX vMotion |

### Anti-Affinity Consideration

A DRS anti-affinity rule **must** be created in the AVS vCenter before Wave 2 begins:

```powershell
# Create anti-affinity rule in AVS vCenter
New-DrsRule -Cluster "Harbor-AVS-Cluster" `
    -Name "APP-AntiAffinity" `
    -VM (Get-VM APP01, APP02) `
    -KeepTogether $false `
    -Enabled $true
```

This ensures APP01 and APP02 are scheduled on different hosts, matching the source
topology where they reside on `esxi-host01` and `esxi-host02` respectively.

### Pre-Migration Checklist

- [ ] Run `validate-pre-migration.ps1 -VMName APP01,APP02` — all checks PASS
- [ ] Wave 1 (DB01) completed and validated successfully (**hard dependency**)
- [ ] DB01 SQL connectivity confirmed from current APP01/APP02 source location
- [ ] API health endpoint (`/health`) returning HTTP 200 on both servers
- [ ] VMware Tools running and current on both VMs
- [ ] No active snapshots on APP01 or APP02
- [ ] No CD/DVD or ISO mounted
- [ ] DNS records verified for `app01.harbor.local` and `app02.harbor.local`
- [ ] Anti-affinity DRS rule created in AVS vCenter
- [ ] Application deployment pipeline paused (no deploys during migration)

### Migration Steps

1. **Migrate APP01 via HCX vMotion** — Near-zero downtime.
2. **Validate APP01** — API health check, DB connectivity, DNS.
3. **Migrate APP02 via HCX vMotion** — Can run in parallel with APP01 validation.
4. **Validate APP02** — Same checks as APP01.
5. **Verify anti-affinity rule** — Confirm VMs on separate hosts.
6. **End-to-end API test** — Run functional test suite against both endpoints.

### Estimated Duration

| Phase | Duration |
|-------|----------|
| Pre-checks & anti-affinity setup | 15 min |
| APP01 vMotion | 20–30 min |
| APP01 validation | 10 min |
| APP02 vMotion (parallel) | 20–30 min |
| APP02 validation + E2E tests | 15 min |
| **Total** | **~1.5 hours** |

### Success Validation

- [ ] APP01 and APP02 powered on in AVS vCenter
- [ ] IP addresses `10.10.20.11` and `10.10.20.12` reachable
- [ ] API health endpoint returns HTTP 200: `GET http://app01.harbor.local/health`
- [ ] API can reach DB01 on AVS: `Invoke-RestMethod http://app01.harbor.local/api/status`
- [ ] Anti-affinity rule active — VMs on different ESXi hosts
- [ ] Application logs show no errors post-migration
- [ ] Response time within 20% of baseline

### Rollback Criteria

Trigger rollback if **any** of:
- Either APP VM does not power on within 10 minutes post-vMotion
- API health endpoint returns non-200 for >5 minutes after migration
- Database connectivity from APP tier to DB01 fails and cannot be resolved in 15 minutes
- >30% latency increase on API calls after 20-minute soak period

**Rollback procedure:** Reverse-vMotion affected VMs to source vCenter. Verify API
endpoints resolve to source IPs. No DB rollback needed — DB01 remains on AVS.

### Dependencies

- **Wave 1 must be complete and validated.** APP tier depends on DB01 connectivity.

---

## Wave 3 — Web Tier (WEB01, WEB02)

**Rationale:** Migrate the web front-ends last. These are the least complex workloads
but require load balancer cutover coordination. With DB and App tiers already on AVS,
the web tier migration completes the stack.

### VM Details

| Property | WEB01 | WEB02 |
|----------|-------|-------|
| Guest OS | Windows Server 2019 | Windows Server 2019 |
| vCPU / RAM | 4 vCPU / 8 GB | 4 vCPU / 8 GB |
| Disks | 1 (100 GB / 45 GB used) | 1 (100 GB / 43 GB used) |
| Network | Web-Segment (10.10.10.11) | Web-Segment (10.10.10.12) |
| Application | IIS — Harbor Retail Portal | IIS — Harbor Retail Portal |
| LB VIP | 192.168.1.100 (portal.harbor.local) | |
| Migration Method | HCX vMotion | HCX vMotion |

### Load Balancer Cutover Plan

The NSX-V load balancer VIP (`192.168.1.100`, HTTPS/443, round-robin) must be
recreated on the AVS NSX-T side after migration:

1. **Before migration:** Document current LB health check config (`/health`, interval 5s, timeout 15s).
2. **During migration:** VIP continues to route to whichever WEB VM is still on source.
3. **After both VMs migrated:** Recreate NSX-T load balancer pool with WEB01 and WEB02.
4. **DNS cutover:** Update `portal.harbor.local` A-record to new VIP if IP changes.
5. **Validation:** `curl https://portal.harbor.local/health` returns HTTP 200.

### Pre-Migration Checklist

- [ ] Run `validate-pre-migration.ps1 -VMName WEB01,WEB02` — all checks PASS
- [ ] Wave 2 (APP01, APP02) completed and validated successfully (**hard dependency**)
- [ ] API endpoints reachable from WEB01/WEB02 source location
- [ ] IIS health endpoint (`/health`) returning HTTP 200 on both servers
- [ ] VMware Tools running and current on both VMs
- [ ] No active snapshots on WEB01 or WEB02
- [ ] No CD/DVD or ISO mounted
- [ ] DNS records verified for `web01.harbor.local` and `web02.harbor.local`
- [ ] Load balancer configuration documented and NSX-T LB pool prepared
- [ ] CDN cache purge scheduled (if applicable)
- [ ] SSL certificates valid and accessible on AVS network

### Migration Steps

1. **Remove WEB02 from LB pool** — Traffic shifts to WEB01 only.
2. **Migrate WEB02 via HCX vMotion** — Validate IIS on WEB02.
3. **Add WEB02 back to LB pool (AVS side)**.
4. **Remove WEB01 from LB pool** — Traffic shifts to WEB02 (now on AVS).
5. **Migrate WEB01 via HCX vMotion** — Validate IIS on WEB01.
6. **Add WEB01 back to LB pool**.
7. **Verify LB VIP health** — Both members healthy, round-robin active.
8. **Update DNS** if VIP address changed.

### Estimated Duration

| Phase | Duration |
|-------|----------|
| Pre-checks & LB prep | 10 min |
| WEB02 drain + vMotion + validation | 20 min |
| WEB01 drain + vMotion + validation | 20 min |
| LB cutover + DNS + E2E validation | 10 min |
| **Total** | **~1 hour** |

### Success Validation

- [ ] WEB01 and WEB02 powered on in AVS vCenter
- [ ] IP addresses `10.10.10.11` and `10.10.10.12` reachable
- [ ] IIS service running on both VMs (`Get-Service W3SVC`)
- [ ] `/health` returns HTTP 200 on both servers directly
- [ ] Load balancer VIP (`192.168.1.100:443`) responds with HTTP 200
- [ ] `portal.harbor.local` resolves correctly and page loads
- [ ] Full end-to-end test: portal → API → DB round-trip succeeds
- [ ] No TLS/SSL certificate errors

### Rollback Criteria

Trigger rollback if **any** of:
- Either WEB VM does not power on within 10 minutes post-vMotion
- IIS fails to start and cannot be resolved within 15 minutes
- Load balancer VIP health check fails for >5 minutes with both members
- End-to-end portal test fails after migration and LB cutover
- >30% increase in page load time after 15-minute soak period

**Rollback procedure:** Reverse-vMotion affected web VMs. Restore NSX-V LB pool
membership. Re-point DNS `portal.harbor.local` to original VIP. APP and DB tiers
remain on AVS.

### Dependencies

- **Wave 2 must be complete and validated.** Web tier depends on APP tier API endpoints.
- Load balancer configuration must be prepared on NSX-T before migration.

---

## Post-Migration (All Waves Complete)

### Final Validation Checklist

- [ ] All 5 VMs powered on and healthy in AVS vCenter
- [ ] Full application stack test: `https://portal.harbor.local` → API → DB
- [ ] Performance baseline comparison (response times, CPU, memory, disk I/O)
- [ ] Monitoring agents reporting to centralized monitoring
- [ ] Backup jobs configured and tested on AVS
- [ ] DRS rules verified (anti-affinity for APP tier)
- [ ] Resource pools recreated (Web-Pool, App-Pool, DB-Pool)
- [ ] DNS records all resolving correctly
- [ ] Source VMs powered off (not deleted — retain for 7 days)
- [ ] Change record closed

### Hypercare Period (72 hours)

- Monitor application performance continuously
- On-call rotation for migration team
- Daily check-in calls at 09:00 and 17:00
- Escalation threshold: any P1/P2 incident triggers war room

### Decommission Schedule

| Task | Timeline | Owner |
|------|----------|-------|
| Remove source VMs from monitoring | T+24 hours | Ops |
| Delete source VM snapshots | T+48 hours | VMware Admin |
| Decommission source VMs | T+7 days | VMware Admin |
| Remove HCX site pairing (optional) | T+14 days | Network |
| Close migration project | T+30 days | Migration Lead |
