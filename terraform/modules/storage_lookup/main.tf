variable "name" {
  type = string
}
variable "resource_group_name" {
  type = string
}


data "azurerm_storage_account" "central_strorage_account" {
  name                = var.name
  resource_group_name = var.resource_group_name
}

output "id" {
  value = data.azurerm_storage_account.central_strorage_account.id
}