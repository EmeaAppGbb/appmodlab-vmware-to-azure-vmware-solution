# Harbor Retail AVS Migration Rollback Plan

## Rollback Decision Criteria

### When to Rollback
- Application non-functional and cannot be resolved within 2 hours
- >30% performance degradation compared to baseline
- Data integrity issues detected
- Critical network connectivity failures

### When NOT to Rollback
- Minor performance issues that can be tuned
- Individual VM issues (fix in place)
- Cosmetic or monitoring alerts

## Rollback Procedures

### Procedure 1: Cancel In-Progress Migration
Applicable when migration is in progress but not yet cutover.

1. Navigate to HCX UI > Migrations > In Progress
2. Select migration job
3. Click "Cancel Migration"
4. Wait for cancellation (2-5 minutes)
5. Verify VMs still running on-premises

**Recovery Time:** 5-10 minutes

### Procedure 2: Reverse Migrate Single Tier
Applicable for Wave 1 or 2 rollback.

#### Example: Rollback Web Tier
```powershell
# From HCX UI
1. Select Source: AVS, Target: On-Premises
2. Select VMs: WEB01, WEB02
3. Migration Type: vMotion
4. Start Migration
5. Monitor progress (15-20 minutes per VM)
```

**Validation:**
```powershell
Get-VM WEB01,WEB02 | Select Name, PowerState, VMHost
Test-NetConnection portal.harbor.local -Port 443
```

**Recovery Time:** 30-45 minutes

### Procedure 3: Full Environment Rollback
Rollback order: DB → App → Web (reverse of migration)

#### Step 1: Database Tier Rollback
```powershell
# Create safety snapshot in AVS
Get-VM DB01 | New-Snapshot -Name "Pre-Rollback-AVS"

# Reverse migrate
# HCX UI: Select DB01, Bulk Migration, Target: On-Premises
```

**Validation:**
```powershell
Invoke-Sqlcmd -ServerInstance db01.harbor.local -Query "DBCC CHECKDB"
```

**Duration:** 2-3 hours

#### Step 2: Application Tier Rollback
Reverse migrate APP01, APP02 using vMotion.  
**Duration:** 45-60 minutes

#### Step 3: Web Tier Rollback
Reverse migrate WEB01, WEB02 using vMotion.  
**Duration:** 30-45 minutes

## Post-Rollback Tasks

### Immediate (Within 1 Hour)
- [ ] Re-enable on-premises backup jobs
- [ ] Restore on-premises monitoring
- [ ] End-to-end application test
- [ ] Notify stakeholders

### Within 24 Hours
- [ ] Remove AVS VMs
- [ ] Remove HCX service mesh (if no longer needed)
- [ ] Document root cause

### Within 1 Week
- [ ] Root cause analysis
- [ ] Update migration plan
- [ ] Reschedule migration (if applicable)

## Communication Templates

### Rollback Initiated
```
TO: Application Owner, Management
SUBJECT: AVS Migration Rollback In Progress

We are rolling back Harbor Retail AVS migration due to [REASON].
Impact: [DESCRIBE]
Expected Completion: [TIME]

Migration Lead: [NAME]
```

### Rollback Complete
```
TO: Application Owner, Management
SUBJECT: AVS Migration Rollback Complete

Harbor Retail environment successfully rolled back to on-premises.
Status: Application fully functional
Next Steps: Root cause analysis, re-migration planning
```

## Rollback Success Criteria
- [ ] All VMs running on-premises
- [ ] Application fully functional
- [ ] Performance meets baseline
- [ ] No data loss
- [ ] Monitoring and backup operational
