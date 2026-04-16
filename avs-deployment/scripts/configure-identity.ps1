#Requires -Modules Az.VMware, ActiveDirectory

<#
.SYNOPSIS
    Extends Active Directory Domain Services to Azure VMware Solution.

.DESCRIPTION
    Configures LDAPS connectivity from the AVS private cloud to an on-premises
    or Azure-hosted AD DS environment, creates AVS-specific service accounts,
    registers the AD identity source in vCenter SSO, and validates domain
    authentication for migrated VMs.

.PARAMETER ResourceGroupName
    Resource group containing the AVS private cloud.

.PARAMETER PrivateCloudName
    Name of the AVS private cloud.

.PARAMETER DomainName
    Fully qualified Active Directory domain name (e.g. contoso.com).

.PARAMETER DomainControllerIP
    IP address of the primary domain controller reachable from AVS.

.PARAMETER LdapsCertPath
    Path to the PFX certificate used for LDAPS (port 636).

.PARAMETER LdapsCertPassword
    SecureString password for the PFX certificate.

.PARAMETER BaseDN
    Base distinguished name for LDAP searches (e.g. DC=contoso,DC=com).

.PARAMETER AdminCredential
    PSCredential with domain-admin privileges for service-account creation.

.PARAMETER Simulate
    Run in dry-run mode without making changes.

.EXAMPLE
    $cred = Get-Credential
    .\configure-identity.ps1 -ResourceGroupName rg-avs -PrivateCloudName pc-avs `
        -DomainName contoso.com -DomainControllerIP 10.0.1.4 `
        -LdapsCertPath .\ldaps.pfx -LdapsCertPassword (Read-Host -AsSecureString) `
        -BaseDN "DC=contoso,DC=com" -AdminCredential $cred -Simulate
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory = $true)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $true)]
    [string]$PrivateCloudName,

    [Parameter(Mandatory = $true)]
    [string]$DomainName,

    [Parameter(Mandatory = $true)]
    [string]$DomainControllerIP,

    [Parameter(Mandatory = $true)]
    [string]$LdapsCertPath,

    [Parameter(Mandatory = $true)]
    [securestring]$LdapsCertPassword,

    [Parameter(Mandatory = $true)]
    [string]$BaseDN,

    [Parameter(Mandatory = $true)]
    [pscredential]$AdminCredential,

    [switch]$Simulate
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Write-Step  { param([string]$Msg) Write-Host "  » $Msg" -ForegroundColor Cyan }
function Write-Ok    { param([string]$Msg) Write-Host "  ✓ $Msg" -ForegroundColor Green }
function Write-Warn  { param([string]$Msg) Write-Host "  ⚠ $Msg" -ForegroundColor Yellow }
function Write-Err   { param([string]$Msg) Write-Host "  ✗ $Msg" -ForegroundColor Red }

# Service accounts to provision for AVS operations
$serviceAccounts = @(
    @{
        Name        = "svc-avs-vcenter"
        DisplayName = "AVS vCenter Service Account"
        Description = "Used by vCenter SSO to bind to Active Directory."
        OU          = "OU=ServiceAccounts,$BaseDN"
    }
    @{
        Name        = "svc-avs-hcx"
        DisplayName = "AVS HCX Service Account"
        Description = "Used by HCX for directory lookups."
        OU          = "OU=ServiceAccounts,$BaseDN"
    }
    @{
        Name        = "svc-avs-backup"
        DisplayName = "AVS Backup Service Account"
        Description = "Used by backup agents for AD-aware operations."
        OU          = "OU=ServiceAccounts,$BaseDN"
    }
)

# VMs to validate domain join
$targetVMs = @("WEB01", "WEB02", "APP01", "APP02", "DB01")

# ============================================================================
# 1. Validate LDAPS Connectivity
# ============================================================================
Write-Host "`n=== LDAPS Connectivity ===" -ForegroundColor White
Write-Step "Testing LDAPS connection to $DomainControllerIP`:636..."

if ($Simulate) {
    Write-Warn "[Simulate] Would test LDAPS connectivity to $DomainControllerIP`:636."
} else {
    try {
        $tcpClient = New-Object System.Net.Sockets.TcpClient
        $connectTask = $tcpClient.ConnectAsync($DomainControllerIP, 636)
        if (-not $connectTask.Wait(5000)) {
            throw "Connection timed out after 5 seconds."
        }

        $sslStream = New-Object System.Net.Security.SslStream($tcpClient.GetStream(), $false)
        $sslStream.AuthenticateAsClient($DomainName)

        Write-Ok "LDAPS connection successful (TLS $($sslStream.SslProtocol))."
        Write-Step "Certificate subject: $($sslStream.RemoteCertificate.Subject)"
        Write-Step "Certificate expires: $($sslStream.RemoteCertificate.GetExpirationDateString())"

        $sslStream.Dispose()
        $tcpClient.Dispose()
    } catch {
        Write-Err "LDAPS connectivity test failed: $_"
        Write-Err "Ensure port 636 is open from AVS to $DomainControllerIP and a valid certificate is installed."
        throw
    }
}

# Validate certificate file
Write-Step "Validating LDAPS certificate at '$LdapsCertPath'..."
if ($Simulate) {
    Write-Warn "[Simulate] Would validate certificate file."
} else {
    if (-not (Test-Path $LdapsCertPath)) {
        Write-Err "Certificate file not found: $LdapsCertPath"
        throw "Certificate file not found."
    }
    try {
        $cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2(
            $LdapsCertPath,
            $LdapsCertPassword,
            [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::DefaultKeySet
        )
        Write-Ok "Certificate loaded — Subject: $($cert.Subject), Expires: $($cert.NotAfter.ToString('yyyy-MM-dd'))"

        if ($cert.NotAfter -lt (Get-Date).AddDays(30)) {
            Write-Warn "Certificate expires within 30 days — plan for renewal."
        }
    } catch {
        Write-Err "Failed to load certificate: $_"
        throw
    }
}

# ============================================================================
# 2. Create AVS Service Accounts in AD
# ============================================================================
Write-Host "`n=== Service Account Provisioning ===" -ForegroundColor White

foreach ($svcAccount in $serviceAccounts) {
    Write-Step "Processing service account '$($svcAccount.Name)'..."

    if ($Simulate) {
        Write-Warn "[Simulate] Would create AD account '$($svcAccount.Name)' in $($svcAccount.OU)."
        continue
    }

    try {
        $existingAccount = Get-ADUser -Filter "SamAccountName -eq '$($svcAccount.Name)'" `
            -Credential $AdminCredential -ErrorAction SilentlyContinue

        if ($existingAccount) {
            Write-Ok "Account '$($svcAccount.Name)' already exists."
        } else {
            # Generate a strong random password
            $passwordBytes = New-Object byte[] 32
            [System.Security.Cryptography.RandomNumberGenerator]::Fill($passwordBytes)
            $svcPassword = [Convert]::ToBase64String($passwordBytes).Substring(0, 24) + "!Aa1"
            $securePassword = ConvertTo-SecureString $svcPassword -AsPlainText -Force

            New-ADUser `
                -Name $svcAccount.Name `
                -SamAccountName $svcAccount.Name `
                -UserPrincipalName "$($svcAccount.Name)@$DomainName" `
                -DisplayName $svcAccount.DisplayName `
                -Description $svcAccount.Description `
                -Path $svcAccount.OU `
                -AccountPassword $securePassword `
                -Enabled $true `
                -PasswordNeverExpires $true `
                -CannotChangePassword $true `
                -Credential $AdminCredential

            Write-Ok "Account '$($svcAccount.Name)' created in $($svcAccount.OU)."
            Write-Warn "Store the generated password securely — it will not be displayed again."
        }
    } catch {
        Write-Err "Failed to create account '$($svcAccount.Name)': $_"
        throw
    }
}

# ============================================================================
# 3. Configure vCenter SSO Identity Source
# ============================================================================
Write-Host "`n=== vCenter SSO Identity Source ===" -ForegroundColor White
Write-Step "Registering AD identity source '$DomainName' in AVS vCenter SSO..."

if ($Simulate) {
    Write-Warn "[Simulate] Would register identity source '$DomainName' via Az.VMware."
} else {
    try {
        # Read the LDAPS certificate content for the SSO configuration
        $certBytes = [System.IO.File]::ReadAllBytes((Resolve-Path $LdapsCertPath))
        $certBase64 = [Convert]::ToBase64String($certBytes)

        # Use the Az.VMware module to configure the identity source
        $svcAccountPlain = $AdminCredential.GetNetworkCredential()

        $identitySourceParams = @{
            ResourceGroupName = $ResourceGroupName
            PrivateCloudName  = $PrivateCloudName
            Name              = $DomainName
            Alias             = $DomainName.Split('.')[0]
            DomainName        = $DomainName
            DomainUsername    = "svc-avs-vcenter@$DomainName"
            DomainPassword    = $svcAccountPlain.Password
            BaseDNUsers       = $BaseDN
            BaseDNGroups      = $BaseDN
            PrimaryUrl        = "ldaps://${DomainControllerIP}:636"
            SslCertificate    = $certBase64
        }

        # Check for existing identity sources
        $existingSources = Get-AzVMwarePrivateCloudIdentitySource `
            -ResourceGroupName $ResourceGroupName `
            -PrivateCloudName $PrivateCloudName -ErrorAction SilentlyContinue

        $alreadyConfigured = $existingSources | Where-Object { $_.DomainName -eq $DomainName }

        if ($alreadyConfigured) {
            Write-Ok "Identity source '$DomainName' is already registered."
        } else {
            New-AzVMwarePrivateCloudIdentitySource @identitySourceParams | Out-Null
            Write-Ok "Identity source '$DomainName' registered in vCenter SSO."
        }
    } catch {
        Write-Err "Failed to configure vCenter SSO identity source: $_"
        Write-Warn "You may need to configure the identity source manually via the Azure portal."
        Write-Warn "Portal path: AVS private cloud → Identity → vCenter SSO → Add identity source"
    }
}

# ============================================================================
# 4. Validate AD Authentication on Migrated VMs
# ============================================================================
Write-Host "`n=== AD Authentication Validation ===" -ForegroundColor White

$validationResults = [System.Collections.Generic.List[PSCustomObject]]::new()

foreach ($vmName in $targetVMs) {
    Write-Step "Validating domain membership for $vmName..."

    if ($Simulate) {
        Write-Warn "[Simulate] Would validate AD authentication on $vmName."
        $validationResults.Add([PSCustomObject]@{
            VM             = $vmName
            DomainJoined   = "Simulated"
            DNSResolution  = "Simulated"
            LDAPSReachable = "Simulated"
        })
        continue
    }

    try {
        $result = Invoke-AzVMRunCommand `
            -ResourceGroupName $ResourceGroupName `
            -VMName $vmName `
            -CommandId "RunPowerShellScript" `
            -ScriptString @"
`$domainInfo = Get-WmiObject Win32_ComputerSystem | Select-Object Domain, PartOfDomain
`$dnsTest = Resolve-DnsName '$DomainName' -ErrorAction SilentlyContinue
`$ldapTest = Test-NetConnection -ComputerName '$DomainControllerIP' -Port 636 -WarningAction SilentlyContinue

[PSCustomObject]@{
    DomainJoined   = `$domainInfo.PartOfDomain
    Domain         = `$domainInfo.Domain
    DNSResolution  = if (`$dnsTest) { 'OK' } else { 'FAILED' }
    LDAPSReachable = `$ldapTest.TcpTestSucceeded
} | ConvertTo-Json
"@

        $output = ($result.Value | Where-Object { $_.Code -eq "ComponentStatus/StdOut/succeeded" }).Message | ConvertFrom-Json

        $validationResults.Add([PSCustomObject]@{
            VM             = $vmName
            DomainJoined   = $output.DomainJoined
            DNSResolution  = $output.DNSResolution
            LDAPSReachable = $output.LDAPSReachable
        })

        if ($output.DomainJoined -eq $true) {
            Write-Ok "$vmName is domain-joined to '$($output.Domain)'."
        } else {
            Write-Warn "$vmName is NOT domain-joined."
        }
    } catch {
        Write-Err "Failed to validate $vmName`: $_"
        $validationResults.Add([PSCustomObject]@{
            VM             = $vmName
            DomainJoined   = "Error"
            DNSResolution  = "Error"
            LDAPSReachable = "Error"
        })
    }
}

# ============================================================================
# Summary
# ============================================================================
Write-Host "`n=== Identity Configuration Summary ===" -ForegroundColor White
Write-Host "  Domain              : $DomainName" -ForegroundColor Gray
Write-Host "  Domain Controller   : $DomainControllerIP (LDAPS:636)" -ForegroundColor Gray
Write-Host "  Service Accounts    : $($serviceAccounts.Count) created/verified" -ForegroundColor Gray
Write-Host "  SSO Identity Source : $DomainName → vCenter SSO" -ForegroundColor Gray

Write-Host "`n  VM Authentication Validation:" -ForegroundColor Gray
$validationResults | Format-Table -AutoSize

$failedVMs = $validationResults | Where-Object { $_.DomainJoined -eq $false -or $_.DomainJoined -eq "Error" }
if ($failedVMs) {
    Write-Warn "$($failedVMs.Count) VM(s) have identity issues — review results above."
} else {
    Write-Ok "All VMs passed AD authentication validation."
}

Write-Host "`n✓ Identity configuration complete!`n" -ForegroundColor Green
