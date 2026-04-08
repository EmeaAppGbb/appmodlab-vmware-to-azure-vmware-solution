# Configure Azure Monitor for AVS
param(
    [Parameter(Mandatory=$true)]
    [string]$ResourceGroupName,
    
    [Parameter(Mandatory=$true)]
    [string]$WorkspaceName,
    
    [Parameter(Mandatory=$true)]
    [string]$PrivateCloudName
)

Write-Host "Configuring Azure Monitor for AVS..." -ForegroundColor Cyan

# Create Log Analytics workspace
Write-Host "Creating Log Analytics workspace..." -ForegroundColor Yellow
az monitor log-analytics workspace create `
    --resource-group $ResourceGroupName `
    --workspace-name $WorkspaceName `
    --location eastus

# Enable diagnostic settings for AVS
Write-Host "Enabling diagnostic settings..." -ForegroundColor Yellow
az monitor diagnostic-settings create `
    --name "AVS-Diagnostics" `
    --resource "/subscriptions/$(az account show --query id -o tsv)/resourceGroups/$ResourceGroupName/providers/Microsoft.AVS/privateClouds/$PrivateCloudName" `
    --workspace $WorkspaceName `
    --logs '[{"category":"VMwareSyslog","enabled":true}]' `
    --metrics '[{"category":"AllMetrics","enabled":true}]'

Write-Host "`n✓ Azure Monitor configured successfully!" -ForegroundColor Green
