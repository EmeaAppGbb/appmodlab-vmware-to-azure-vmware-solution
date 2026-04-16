// =============================================================================
// Azure Integration — Private Endpoints, DNS, Front Door & VNet Peering
// Harbor Retail - VMware to Azure VMware Solution Migration
// =============================================================================
//
// Deploys Azure native service connectivity for AVS workloads:
//   • Private DNS zones for Azure SQL and Blob Storage
//   • Private endpoints in a dedicated subnet
//   • Azure Front Door for public web-tier ingress
//   • VNet peering between transit and application VNets
//   • NSG rules governing private-endpoint traffic
// =============================================================================

// -----------------------------------------------------------------------------
// Parameters
// -----------------------------------------------------------------------------

@description('Azure region for all resources.')
param location string = 'eastus'

@description('Name of the resource group.')
param resourceGroupName string = 'rg-harbor-retail-avs'

@description('Resource ID of the existing transit virtual network.')
param transitVnetId string

@description('Name of the application virtual network.')
param appVnetName string = 'vnet-harbor-retail-app'

@description('Address space for the application virtual network.')
param appVnetAddressSpace string = '10.210.0.0/16'

@description('Address prefix for the private-endpoint subnet.')
param privateEndpointSubnetPrefix string = '10.210.1.0/24'

@description('Address prefix for the application workload subnet.')
param appSubnetPrefix string = '10.210.2.0/24'

@description('Name of the existing Azure SQL Server (logical server).')
param sqlServerName string = 'sql-harbor-retail'

@description('Name of the existing Azure Storage account.')
param storageAccountName string = 'stharborretail'

@description('Name of the Azure Front Door profile.')
param frontDoorProfileName string = 'afd-harbor-retail'

@description('Tags applied to all resources.')
param tags object = {
  project: 'harbor-retail'
  environment: 'production'
  workload: 'azure-integration'
  managed_by: 'bicep'
}

// -----------------------------------------------------------------------------
// Variables
// -----------------------------------------------------------------------------

var transitVnetName = split(transitVnetId, '/')[8]
var transitVnetResourceGroup = split(transitVnetId, '/')[4]

// -----------------------------------------------------------------------------
// Application Virtual Network
// -----------------------------------------------------------------------------

resource appVnet 'Microsoft.Network/virtualNetworks@2023-05-01' = {
  name: appVnetName
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [
        appVnetAddressSpace
      ]
    }
    subnets: [
      {
        name: 'snet-private-endpoints'
        properties: {
          addressPrefix: privateEndpointSubnetPrefix
          networkSecurityGroup: {
            id: privateEndpointNsg.id
          }
          privateEndpointNetworkPolicies: 'Disabled'
        }
      }
      {
        name: 'snet-app-workloads'
        properties: {
          addressPrefix: appSubnetPrefix
          networkSecurityGroup: {
            id: appWorkloadNsg.id
          }
        }
      }
    ]
  }
  tags: tags
}

// -----------------------------------------------------------------------------
// Network Security Groups
// -----------------------------------------------------------------------------

resource privateEndpointNsg 'Microsoft.Network/networkSecurityGroups@2023-05-01' = {
  name: 'nsg-harbor-retail-pe'
  location: location
  properties: {
    securityRules: [
      {
        name: 'AllowSqlFromAvs'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: '10.100.0.0/22' // AVS management CIDR
          destinationAddressPrefix: privateEndpointSubnetPrefix
          sourcePortRange: '*'
          destinationPortRange: '1433'
          description: 'Allow SQL traffic from AVS workloads'
        }
      }
      {
        name: 'AllowBlobFromAvs'
        properties: {
          priority: 110
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: '10.100.0.0/22'
          destinationAddressPrefix: privateEndpointSubnetPrefix
          sourcePortRange: '*'
          destinationPortRange: '443'
          description: 'Allow HTTPS (Blob) traffic from AVS workloads'
        }
      }
      {
        name: 'AllowSqlFromAppSubnet'
        properties: {
          priority: 120
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: appSubnetPrefix
          destinationAddressPrefix: privateEndpointSubnetPrefix
          sourcePortRange: '*'
          destinationPortRange: '1433'
          description: 'Allow SQL traffic from app workload subnet'
        }
      }
      {
        name: 'AllowBlobFromAppSubnet'
        properties: {
          priority: 130
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: appSubnetPrefix
          destinationAddressPrefix: privateEndpointSubnetPrefix
          sourcePortRange: '*'
          destinationPortRange: '443'
          description: 'Allow HTTPS (Blob) traffic from app workload subnet'
        }
      }
      {
        name: 'DenyAllInbound'
        properties: {
          priority: 4096
          direction: 'Inbound'
          access: 'Deny'
          protocol: '*'
          sourceAddressPrefix: '*'
          destinationAddressPrefix: '*'
          sourcePortRange: '*'
          destinationPortRange: '*'
          description: 'Deny all other inbound traffic to private endpoints'
        }
      }
    ]
  }
  tags: tags
}

resource appWorkloadNsg 'Microsoft.Network/networkSecurityGroups@2023-05-01' = {
  name: 'nsg-harbor-retail-app'
  location: location
  properties: {
    securityRules: [
      {
        name: 'AllowHttpsFromFrontDoor'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: 'AzureFrontDoor.Backend'
          destinationAddressPrefix: appSubnetPrefix
          sourcePortRange: '*'
          destinationPortRange: '443'
          description: 'Allow HTTPS from Azure Front Door'
        }
      }
      {
        name: 'AllowHttpFromFrontDoor'
        properties: {
          priority: 110
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: 'AzureFrontDoor.Backend'
          destinationAddressPrefix: appSubnetPrefix
          sourcePortRange: '*'
          destinationPortRange: '80'
          description: 'Allow HTTP from Azure Front Door'
        }
      }
    ]
  }
  tags: tags
}

// -----------------------------------------------------------------------------
// Private DNS Zones
// -----------------------------------------------------------------------------

resource privateDnsZoneSql 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  name: 'privatelink.database.windows.net'
  location: 'global'
  tags: tags
}

resource privateDnsZoneBlob 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  name: 'privatelink.blob.core.windows.net'
  location: 'global'
  tags: tags
}

// Link DNS zones to the application VNet
resource dnsLinkSqlAppVnet 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = {
  parent: privateDnsZoneSql
  name: 'link-sql-to-app-vnet'
  location: 'global'
  properties: {
    virtualNetwork: {
      id: appVnet.id
    }
    registrationEnabled: false
  }
  tags: tags
}

resource dnsLinkBlobAppVnet 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = {
  parent: privateDnsZoneBlob
  name: 'link-blob-to-app-vnet'
  location: 'global'
  properties: {
    virtualNetwork: {
      id: appVnet.id
    }
    registrationEnabled: false
  }
  tags: tags
}

// Link DNS zones to the transit VNet for AVS DNS forwarding
resource dnsLinkSqlTransitVnet 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = {
  parent: privateDnsZoneSql
  name: 'link-sql-to-transit-vnet'
  location: 'global'
  properties: {
    virtualNetwork: {
      id: transitVnetId
    }
    registrationEnabled: false
  }
  tags: tags
}

resource dnsLinkBlobTransitVnet 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = {
  parent: privateDnsZoneBlob
  name: 'link-blob-to-transit-vnet'
  location: 'global'
  properties: {
    virtualNetwork: {
      id: transitVnetId
    }
    registrationEnabled: false
  }
  tags: tags
}

// -----------------------------------------------------------------------------
// Private Endpoints
// -----------------------------------------------------------------------------

resource sqlServer 'Microsoft.Sql/servers@2023-05-01-preview' existing = {
  name: sqlServerName
}

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-01-01' existing = {
  name: storageAccountName
}

resource sqlPrivateEndpoint 'Microsoft.Network/privateEndpoints@2023-05-01' = {
  name: 'pe-harbor-retail-sql'
  location: location
  properties: {
    subnet: {
      id: appVnet.properties.subnets[0].id
    }
    privateLinkServiceConnections: [
      {
        name: 'plsc-sql'
        properties: {
          privateLinkServiceId: sqlServer.id
          groupIds: [
            'sqlServer'
          ]
        }
      }
    ]
  }
  tags: tags
}

resource blobPrivateEndpoint 'Microsoft.Network/privateEndpoints@2023-05-01' = {
  name: 'pe-harbor-retail-blob'
  location: location
  properties: {
    subnet: {
      id: appVnet.properties.subnets[0].id
    }
    privateLinkServiceConnections: [
      {
        name: 'plsc-blob'
        properties: {
          privateLinkServiceId: storageAccount.id
          groupIds: [
            'blob'
          ]
        }
      }
    ]
  }
  tags: tags
}

// DNS zone group registrations (auto-create A records in Private DNS)
resource sqlDnsZoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2023-05-01' = {
  parent: sqlPrivateEndpoint
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'sql-dns-config'
        properties: {
          privateDnsZoneId: privateDnsZoneSql.id
        }
      }
    ]
  }
}

resource blobDnsZoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2023-05-01' = {
  parent: blobPrivateEndpoint
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'blob-dns-config'
        properties: {
          privateDnsZoneId: privateDnsZoneBlob.id
        }
      }
    ]
  }
}

// -----------------------------------------------------------------------------
// Azure Front Door
// -----------------------------------------------------------------------------

resource frontDoorProfile 'Microsoft.Cdn/profiles@2023-05-01' = {
  name: frontDoorProfileName
  location: 'global'
  sku: {
    name: 'Standard_AzureFrontDoor'
  }
  tags: tags
}

resource frontDoorEndpoint 'Microsoft.Cdn/profiles/afdEndpoints@2023-05-01' = {
  parent: frontDoorProfile
  name: 'fde-harbor-retail-web'
  location: 'global'
  properties: {
    enabledState: 'Enabled'
  }
  tags: tags
}

// -----------------------------------------------------------------------------
// VNet Peering — Transit ↔ Application
// -----------------------------------------------------------------------------

resource peeringTransitToApp 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2023-05-01' = {
  name: '${appVnetName}/peer-app-to-transit'
  properties: {
    remoteVirtualNetwork: {
      id: transitVnetId
    }
    allowVirtualNetworkAccess: true
    allowForwardedTraffic: true
    allowGatewayTransit: false
    useRemoteGateways: true
  }
  dependsOn: [
    appVnet
  ]
}

// NOTE: The transit-to-app peering must be created in the transit VNet's resource
// group. When transit and app share the same RG this works directly; otherwise
// use a module scoped to the transit RG.

resource peeringAppToTransit 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2023-05-01' = {
  name: 'vnet-harbor-retail-transit/peer-transit-to-app'
  properties: {
    remoteVirtualNetwork: {
      id: appVnet.id
    }
    allowVirtualNetworkAccess: true
    allowForwardedTraffic: true
    allowGatewayTransit: true
    useRemoteGateways: false
  }
}

// -----------------------------------------------------------------------------
// Outputs
// -----------------------------------------------------------------------------

output appVnetId string = appVnet.id
output privateEndpointSubnetId string = appVnet.properties.subnets[0].id
output sqlPrivateEndpointId string = sqlPrivateEndpoint.id
output blobPrivateEndpointId string = blobPrivateEndpoint.id
output sqlPrivateDnsZoneId string = privateDnsZoneSql.id
output blobPrivateDnsZoneId string = privateDnsZoneBlob.id
output frontDoorProfileId string = frontDoorProfile.id
output frontDoorEndpointHostName string = frontDoorEndpoint.properties.hostName
output peeringTransitToAppId string = peeringTransitToApp.id
output peeringAppToTransitId string = peeringAppToTransit.id
