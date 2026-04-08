// =============================================================================
// Azure VMware Solution (AVS) Private Cloud Deployment
// Harbor Retail - VMware to Azure VMware Solution Migration
// =============================================================================

targetScope = 'subscription'

// -----------------------------------------------------------------------------
// Parameters
// -----------------------------------------------------------------------------

@description('Azure region for all resources.')
param location string = 'eastus'

@description('Name of the resource group.')
param resourceGroupName string = 'rg-harbor-retail-avs'

@description('Name of the AVS private cloud.')
param avsPrivateCloudName string = 'pc-harbor-retail'

@description('SKU for AVS hosts.')
@allowed(['av36', 'av36t', 'av36p', 'av52'])
param avsSku string = 'av36'

@description('Number of hosts in the management cluster (minimum 3).')
@minValue(3)
param avsClusterSize int = 3

@description('CIDR block for the AVS management network (/22 required).')
param avsManagementCidr string = '10.100.0.0/22'

@description('Address space for the transit virtual network.')
param vnetAddressSpace string = '10.200.0.0/16'

@description('Address prefix for the GatewaySubnet.')
param gatewaySubnetPrefix string = '10.200.0.0/24'

@description('Name for the ExpressRoute authorization key.')
param expressRouteAuthKeyName string = 'harbor-retail-auth-key'

@description('Tags applied to all resources.')
param tags object = {
  project: 'harbor-retail'
  environment: 'production'
  workload: 'avs-migration'
  managed_by: 'bicep'
}

// -----------------------------------------------------------------------------
// Resource Group
// -----------------------------------------------------------------------------

resource rg 'Microsoft.Resources/resourceGroups@2023-07-01' = {
  name: resourceGroupName
  location: location
  tags: tags
}

// -----------------------------------------------------------------------------
// Module: AVS and Networking Resources
// -----------------------------------------------------------------------------

module avsDeployment 'avs-resources.bicep' = {
  name: 'avs-resources-deployment'
  scope: rg
  params: {
    location: location
    avsPrivateCloudName: avsPrivateCloudName
    avsSku: avsSku
    avsClusterSize: avsClusterSize
    avsManagementCidr: avsManagementCidr
    vnetAddressSpace: vnetAddressSpace
    gatewaySubnetPrefix: gatewaySubnetPrefix
    expressRouteAuthKeyName: expressRouteAuthKeyName
    tags: tags
  }
}

// -----------------------------------------------------------------------------
// Outputs
// -----------------------------------------------------------------------------

output resourceGroupName string = rg.name
output avsPrivateCloudId string = avsDeployment.outputs.avsPrivateCloudId
output vCenterEndpoint string = avsDeployment.outputs.vCenterEndpoint
output nsxtManagerEndpoint string = avsDeployment.outputs.nsxtManagerEndpoint
output transitVnetId string = avsDeployment.outputs.transitVnetId
output expressRouteGatewayId string = avsDeployment.outputs.expressRouteGatewayId
