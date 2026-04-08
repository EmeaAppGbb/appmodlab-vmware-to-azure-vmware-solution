# =============================================================================
# Azure VMware Solution (AVS) Private Cloud Deployment
# Harbor Retail - VMware to Azure VMware Solution Migration
# =============================================================================

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.80"
    }
  }
}

provider "azurerm" {
  features {}
}

# -----------------------------------------------------------------------------
# Variables
# -----------------------------------------------------------------------------

variable "location" {
  type        = string
  default     = "eastus"
  description = "Azure region for all resources."
}

variable "resource_group_name" {
  type        = string
  default     = "rg-harbor-retail-avs"
  description = "Name of the resource group."
}

variable "avs_private_cloud_name" {
  type        = string
  default     = "pc-harbor-retail"
  description = "Name of the AVS private cloud."
}

variable "avs_sku" {
  type        = string
  default     = "av36"
  description = "SKU for AVS hosts (av36, av36t, av36p, av52)."
}

variable "avs_cluster_size" {
  type        = number
  default     = 3
  description = "Number of hosts in the management cluster (minimum 3)."
}

variable "avs_management_cidr" {
  type        = string
  default     = "10.100.0.0/22"
  description = "CIDR block for the AVS management network (/22 required)."
}

variable "vnet_address_space" {
  type        = string
  default     = "10.200.0.0/16"
  description = "Address space for the transit virtual network."
}

variable "gateway_subnet_prefix" {
  type        = string
  default     = "10.200.0.0/24"
  description = "Address prefix for the GatewaySubnet."
}

variable "expressroute_auth_key_name" {
  type        = string
  default     = "harbor-retail-auth-key"
  description = "Name for the ExpressRoute authorization key."
}

variable "tags" {
  type = map(string)
  default = {
    project     = "harbor-retail"
    environment = "production"
    workload    = "avs-migration"
    managed_by  = "terraform"
  }
  description = "Tags applied to all resources."
}

# -----------------------------------------------------------------------------
# Resource Group
# -----------------------------------------------------------------------------

resource "azurerm_resource_group" "avs" {
  name     = var.resource_group_name
  location = var.location
  tags     = var.tags
}

# -----------------------------------------------------------------------------
# AVS Private Cloud
# -----------------------------------------------------------------------------

resource "azurerm_vmware_private_cloud" "harbor_retail" {
  name                = var.avs_private_cloud_name
  resource_group_name = azurerm_resource_group.avs.name
  location            = azurerm_resource_group.avs.location

  sku_name = var.avs_sku

  management_cluster {
    size = var.avs_cluster_size
  }

  network_subnet_cidr         = var.avs_management_cidr
  internet_connection_enabled = false

  tags = var.tags
}

# -----------------------------------------------------------------------------
# ExpressRoute Authorization Key
# -----------------------------------------------------------------------------

resource "azurerm_vmware_express_route_authorization" "harbor_retail" {
  name             = var.expressroute_auth_key_name
  private_cloud_id = azurerm_vmware_private_cloud.harbor_retail.id
}

# -----------------------------------------------------------------------------
# Transit Virtual Network
# -----------------------------------------------------------------------------

resource "azurerm_virtual_network" "transit" {
  name                = "vnet-harbor-retail-transit"
  location            = azurerm_resource_group.avs.location
  resource_group_name = azurerm_resource_group.avs.name
  address_space       = [var.vnet_address_space]
  tags                = var.tags
}

resource "azurerm_subnet" "gateway" {
  name                 = "GatewaySubnet"
  resource_group_name  = azurerm_resource_group.avs.name
  virtual_network_name = azurerm_virtual_network.transit.name
  address_prefixes     = [var.gateway_subnet_prefix]
}

# -----------------------------------------------------------------------------
# ExpressRoute Virtual Network Gateway
# -----------------------------------------------------------------------------

resource "azurerm_public_ip" "gateway" {
  name                = "pip-harbor-retail-ergw"
  location            = azurerm_resource_group.avs.location
  resource_group_name = azurerm_resource_group.avs.name
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = var.tags
}

resource "azurerm_virtual_network_gateway" "expressroute" {
  name                = "ergw-harbor-retail"
  location            = azurerm_resource_group.avs.location
  resource_group_name = azurerm_resource_group.avs.name

  type = "ExpressRoute"
  sku  = "ErGw1AZ"

  ip_configuration {
    name                          = "ergw-ipconfig"
    public_ip_address_id          = azurerm_public_ip.gateway.id
    private_ip_address_allocation = "Dynamic"
    subnet_id                     = azurerm_subnet.gateway.id
  }

  tags = var.tags
}

# -----------------------------------------------------------------------------
# ExpressRoute Connection (AVS to VNet)
# -----------------------------------------------------------------------------

resource "azurerm_virtual_network_gateway_connection" "avs" {
  name                = "conn-harbor-retail-avs"
  location            = azurerm_resource_group.avs.location
  resource_group_name = azurerm_resource_group.avs.name

  type                       = "ExpressRoute"
  virtual_network_gateway_id = azurerm_virtual_network_gateway.expressroute.id
  express_route_circuit_id   = azurerm_vmware_private_cloud.harbor_retail.circuit[0].express_route_id
  authorization_key          = azurerm_vmware_express_route_authorization.harbor_retail.express_route_authorization_key

  tags = var.tags
}

# -----------------------------------------------------------------------------
# Outputs
# -----------------------------------------------------------------------------

output "resource_group_name" {
  value       = azurerm_resource_group.avs.name
  description = "Name of the resource group."
}

output "avs_private_cloud_id" {
  value       = azurerm_vmware_private_cloud.harbor_retail.id
  description = "Resource ID of the AVS private cloud."
}

output "vcenter_endpoint" {
  value       = azurerm_vmware_private_cloud.harbor_retail.vcsa_endpoint
  description = "vCenter Server endpoint URL."
}

output "nsxt_manager_endpoint" {
  value       = azurerm_vmware_private_cloud.harbor_retail.nsxt_manager_endpoint
  description = "NSX-T Manager endpoint URL."
}

output "hcx_cloud_manager_endpoint" {
  value       = azurerm_vmware_private_cloud.harbor_retail.hcx_cloud_manager_endpoint
  description = "HCX Cloud Manager endpoint URL."
}

output "expressroute_circuit_id" {
  value       = azurerm_vmware_private_cloud.harbor_retail.circuit[0].express_route_id
  description = "ExpressRoute circuit ID for the AVS private cloud."
}

output "expressroute_authorization_key" {
  value       = azurerm_vmware_express_route_authorization.harbor_retail.express_route_authorization_key
  description = "ExpressRoute authorization key."
  sensitive   = true
}

output "transit_vnet_id" {
  value       = azurerm_virtual_network.transit.id
  description = "Resource ID of the transit virtual network."
}

output "expressroute_gateway_id" {
  value       = azurerm_virtual_network_gateway.expressroute.id
  description = "Resource ID of the ExpressRoute gateway."
}
