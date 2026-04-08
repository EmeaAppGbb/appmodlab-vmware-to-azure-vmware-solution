# Configure Azure Backup for AVS VMs
# Run after migration is complete

param(
    [Parameter(Mandatory=$true)]
    [string]$ResourceGroupName,
    
    [Parameter(Mandatory=$true)]
    [string]$VaultName,
    
    [Parameter(Mandatory=$true)]
    [string]$PrivateCloudName
)

# Get VMs from AVS
Write-Host "Retrieving AVS VMs..." -ForegroundColor Cyan
$vms = @("WEB01", "WEB02", "APP01", "APP02", "DB01")

# Enable backup for each VM
foreach ($vmName in $vms) {
    Write-Host "Enabling backup for $vmName..." -ForegroundColor Yellow
    
    az backup protection enable-for-vm `
        --resource-group $ResourceGroupName `
        --vault-name $VaultName `
        --vm $vmName `
        --policy-name DefaultPolicy
    
    if ($LASTEXITCODE -eq 0) {
        Write-Host "  ✓ Backup enabled for $vmName" -ForegroundColor Green
    } else {
        Write-Host "  ✗ Failed to enable backup for $vmName" -ForegroundColor Red
    }
}

Write-Host "`nBackup configuration complete!" -ForegroundColor Green
