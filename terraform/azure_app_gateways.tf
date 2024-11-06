
# # Public IP Address for the Application Gateway
# resource "azurerm_public_ip" "app_gw_pip" {
#   for_each = local.azure_config.appGateways
#   name                = each.key
#   location            = each.value["location"]
#   resource_group_name = local.azure_config.resourceGroup
#   allocation_method   = "Static"
#   sku                 = "Standard"
#   zones               = ["1", "2", "3"]
# }


# # Application Gateway with Path-Based Routing
# resource "azurerm_application_gateway" "app_gw" {
#   for_each = local.azure_config.appGateways
#   name                = each.key
#   resource_group_name = local.azure_config.resourceGroup
#   location            = each.value["location"]
#   sku {
#     name     = "Standard_v2"
#     tier     = "Standard_v2"
#     capacity = 1
#   }
#   zones = ["1", "2", "3"]

#   gateway_ip_configuration {
#     name  = "${each.key}-gw-ip-config"
#     subnet_id = azurerm_subnet.subnets[each.value["subnet"]].id
#   }

#   frontend_ip_configuration {
#     name                 = "${each.key}-fontend-ip-config"
#     public_ip_address_id = azurerm_public_ip[each.key].id
#   }

#   frontend_port {
#     name = "${each.key}-frontendPort"
#     port = 80
#   }

#   backend_address_pool {
#     name = "backendPoolApi"
#   }

#   backend_address_pool {
#     name = "backendPoolImages"
#   }

#   backend_http_settings {
#     name                  = "httpSettingsApi"
#     cookie_based_affinity  = "Disabled"
#     port                  = 80
#     protocol              = "Http"
#     request_timeout       = 20
#   }

#   backend_http_settings {
#     name                  = "httpSettingsImages"
#     cookie_based_affinity  = "Disabled"
#     port                  = 80
#     protocol              = "Http"
#     request_timeout       = 20
#   }

#   http_listener {
#     name                           = "appGwHttpListener"
#     frontend_ip_configuration_name = "appGwFrontendIP"
#     frontend_port_name             = "frontendPort"
#     protocol                       = "Http"
#   }

#   # URL Path Map for Path-Based Routing
#   url_path_map {
#     name               = "pathMap"
#     default_backend_address_pool_name  = "backendPoolApi"
#     default_backend_http_settings_name = "httpSettingsApi"

#     path_rule {
#       name                       = "imagesRule"
#       paths                      = ["/images/*"]
#       backend_address_pool_name   = "backendPoolImages"
#       backend_http_settings_name  = "httpSettingsImages"
#     }
#   }

#   request_routing_rule {
#     name                       = "pathBasedRoutingRule"
#     rule_type                  = "PathBasedRouting"
#     http_listener_name         = "appGwHttpListener"
#     url_path_map_name          = "pathMap"
#   }

#   tags = {
#     marketplaceItemId = "Microsoft.ApplicationGateway"
#   }
# }


# resource "azurerm_network_interface_backend_address_pool_association" "app_gw_nic_pool" {
#     for_each = local.azure_config.appGateways
# }
