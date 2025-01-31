resource "azurerm_resource_group" "rg" {
  count    = local.azure_config.resourceGroup == "" ? 0 : 1
  name     = local.azure_config.resourceGroup
  location = local.azure_config.location
}

resource "azurerm_virtual_network" "vnets" {
  for_each            = local.azure_config.vnets
  name                = each.key
  address_space       = [each.value["addressSpace"]]
  location            = azurerm_resource_group.rg[0].location
  resource_group_name = azurerm_resource_group.rg[0].name
}

resource "azurerm_subnet" "subnets" {
  for_each = {
    for subnet in local.vnet_subnets : "${subnet.vnet_name}.${subnet.subnet_key}" => subnet if subnet.subnet_key != "DBSubnet"
  }
  name                 = each.value["subnet_key"]
  resource_group_name  = azurerm_resource_group.rg[0].name
  virtual_network_name = each.value["vnet_name"]
  address_prefixes     = [each.value["address_space"]]
}

resource "azurerm_subnet" "db_subnets" {
  for_each = {
    for subnet in local.vnet_subnets : "${subnet.vnet_name}.${subnet.subnet_key}" => subnet if subnet.subnet_key == "DBSubnet"
  }
  name                 = each.value["subnet_key"]
  resource_group_name  = azurerm_resource_group.rg[0].name
  virtual_network_name = each.value["vnet_name"]
  address_prefixes     = [each.value["address_space"]]

  service_endpoints = ["Microsoft.Sql"] # Allow access to Azure SQL Database


  delegation {
    name = "dbServiceDelegation"
    service_delegation {
      name    = "Microsoft.Sql/managedInstances"
      actions = ["Microsoft.Network/virtualNetworks/subnets/join/action", "Microsoft.Network/virtualNetworks/subnets/prepareNetworkPolicies/action", "Microsoft.Network/virtualNetworks/subnets/unprepareNetworkPolicies/action"]
    }
  }

}

resource "azurerm_virtual_network_peering" "vnets_peering-1" {
  for_each                     = local.azure_config.vnetPairings
  name                         = "${each.key}-1"
  resource_group_name          = local.azure_config.resourceGroup
  virtual_network_name         = each.value[1]
  remote_virtual_network_id    = azurerm_virtual_network.vnets[each.value[0]].id
  allow_virtual_network_access = true
  allow_forwarded_traffic      = false
  allow_gateway_transit        = false
  use_remote_gateways          = false
}

resource "azurerm_virtual_network_peering" "vnets_peering-2" {
  for_each                     = local.azure_config.vnetPairings
  name                         = "${each.key}-2"
  resource_group_name          = local.azure_config.resourceGroup
  virtual_network_name         = each.value[0]
  remote_virtual_network_id    = azurerm_virtual_network.vnets[each.value[1]].id
  allow_virtual_network_access = true
  allow_forwarded_traffic      = false
  allow_gateway_transit        = false
  use_remote_gateways          = false
}


resource "azurerm_route_table" "azure_rt" {
  for_each = {
    for subnet in local.vnet_subnets : "${subnet.vnet_name}.${subnet.subnet_key}" => subnet if subnet.subnet_key == "DBSubnet"
  }
  name                =  each.key
  location = local.azure_config.location
  resource_group_name  = azurerm_resource_group.rg[0].name

  # route {
  #   name                   = "example"
  #   address_prefix         = "10.100.0.0/14"
  #   next_hop_type          = "VirtualAppliance"
  #   next_hop_in_ip_address = "10.10.1.1"
  # }
}

resource "azurerm_subnet_route_table_association" "azure_rta" {
  for_each = {
    for subnet in local.vnet_subnets : "${subnet.vnet_name}.${subnet.subnet_key}" => subnet if subnet.subnet_key == "DBSubnet"
  }
  subnet_id      = azurerm_subnet.db_subnets[each.key].id
  route_table_id = azurerm_route_table.azure_rt[each.key].id
}

resource "azurerm_storage_account" "vnet_storage" {
  for_each            = { for k, v in local.azure_config.vnetFlowLogs : k => v if v.logFlows && !local.azure_config.centralLogging }
  name                = replace(replace("${local.azure_config.resourceGroup}-${each.key}", "-", ""), "_", "")
  resource_group_name = local.azure_config.resourceGroup
  location            = local.azure_config.location

  account_tier              = "Standard"
  account_kind              = "StorageV2"
  account_replication_type  = "LRS"
}

data "azurerm_storage_account" "central_vnet_storage" {
  name                = local.azure_config.blobFlowLogName
  resource_group_name = local.azure_config.blobFlowLogRG
}

resource "azurerm_network_watcher_flow_log" "vnet_flow_log" {
  for_each             = { for k, v in local.azure_config.vnetFlowLogs : k => v if v.logFlows }
  network_watcher_name = "NetworkWatcher_eastus" # make this dynamic
  resource_group_name  = "NetworkWatcherRG"
  name                 = each.key

  target_resource_id   = azurerm_virtual_network.vnets[each.key].id
  storage_account_id   = local.azure_config.centralLogging ? data.azurerm_storage_account.central_vnet_storage.id : azurerm_storage_account.vnet_storage[each.key].id
  enabled              = true
  version              = 2

  retention_policy {
    enabled = true
    days    = 7
  }
}