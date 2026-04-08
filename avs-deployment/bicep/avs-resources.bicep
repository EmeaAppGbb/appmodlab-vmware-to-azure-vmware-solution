// =============================================================================
// AVS Resources Module (resource-group scoped)
// Harbor Retail - VMware to Azure VMware Solution Migration
// =============================================================================

// -----------------------------------------------------------------------------
// Parameters
// -----------------------------------------------------------------------------

param location string
param avsPrivateCloudName string
param avsSku string
param avsClusterSize int
param avsManagementCidr string
param vnetAddressSpace string
param gatewaySubnetPrefix string
param expressRouteAuthKeyName string
param tags object

// -----------------------------------------------------------------------------
// AVS Private Cloud
// -----------------------------------------------------------------------------

resource avsPrivateCloud 'Microsoft.AVS/privateClouds@2023-03-01' = {
  name: avsPrivateCloudName
  location: location
  sku: {
    name: avsSku
  }
  properties: {
    managementCluster: {
      clusterSize: avsClusterSize
    }
    networkBlock: avsManagementCidr
    internet: 'Disabled'
  }
  tags: tags
}

// -----------------------------------------------------------------------------
// ExpressRoute Authorization Key
// -----------------------------------------------------------------------------

resource expressRouteAuth 'Microsoft.AVS/privateClouds/authorizations@2023-03-01' = {
  parent: avsPrivateCloud
  name: expressRouteAuthKeyName
}

// -----------------------------------------------------------------------------
// Transit Virtual Network
// -----------------------------------------------------------------------------

resource transitVnet 'Microsoft.Network/virtualNetworks@2023-05-01' = {
  name: 'vnet-harbor-retail-transit'
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [
        vnetAddressSpace
      ]
    }
    subnets: [
      {
        name: 'GatewaySubnet'
        properties: {
          addressPrefix: gatewaySubnetPrefix
        }
      }
    ]
  }
  tags: tags
}

// -----------------------------------------------------------------------------
// ExpressRoute Virtual Network Gateway
// -----------------------------------------------------------------------------

resource gatewayPip 'Microsoft.Network/publicIPAddresses@2023-05-01' = {
  name: 'pip-harbor-retail-ergw'
  location: location
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
  }
  tags: tags
}

resource expressRouteGateway 'Microsoft.Network/virtualNetworkGateways@2023-05-01' = {
  name: 'ergw-harbor-retail'
  location: location
  properties: {
    gatewayType: 'ExpressRoute'
    sku: {
      name: 'ErGw1AZ'
      tier: 'ErGw1AZ'
    }
    ipConfigurations: [
      {
        name: 'ergw-ipconfig'
        properties: {
          publicIPAddress: {
            id: gatewayPip.id
          }
          subnet: {
            id: transitVnet.properties.subnets[0].id
          }
        }
      }
    ]
  }
  tags: tags
}

// -----------------------------------------------------------------------------
// ExpressRoute Connection (AVS to VNet)
// -----------------------------------------------------------------------------

resource expressRouteConnection 'Microsoft.Network/connections@2023-05-01' = {
  name: 'conn-harbor-retail-avs'
  location: location
  properties: {
    connectionType: 'ExpressRoute'
    virtualNetworkGateway1: {
      id: expressRouteGateway.id
    }
    peer: {
      id: avsPrivateCloud.properties.circuit.expressRouteID
    }
    authorizationKey: expressRouteAuth.properties.expressRouteAuthorizationKey
  }
  tags: tags
}

// -----------------------------------------------------------------------------
// Outputs
// -----------------------------------------------------------------------------

output avsPrivateCloudId string = avsPrivateCloud.id
output vCenterEndpoint string = avsPrivateCloud.properties.endpoints.vcsa
output nsxtManagerEndpoint string = avsPrivateCloud.properties.endpoints.nsxtManager
output hcxCloudManagerEndpoint string = avsPrivateCloud.properties.endpoints.hcxCloudManager
output expressRouteCircuitId string = avsPrivateCloud.properties.circuit.expressRouteID
output transitVnetId string = transitVnet.id
output expressRouteGatewayId string = expressRouteGateway.id
