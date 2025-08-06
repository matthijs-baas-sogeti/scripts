resource "random_string" "random" {
  length  = 5
  special = false
  upper   = false
  numeric = false
}

module "aks" {
  source    = ""
  fullname  = format("%s-%s-%s-%s", local.naming.workload, local.naming.environment, local.naming.region, random_string.random.result)
  shortname = format("%s%s%s%s", local.naming.workload, local.naming.environment, local.naming.region, random_string.random.result)
  location  = local.aks.location

  acr_existing_acr_id = data.azurerm_container_registry.acr.id

  aks_dns_id                  = data.azurerm_private_dns_zone.aks_dns.id
  aks_number_of_node_pools    = local.aks.aks_number_of_node_pools
  aks_system_nodes_subnet_ids = [data.azurerm_subnet.system_nodes_subnet.id]
  aks_system_pods_subnet_ids  = [data.azurerm_subnet.system_pods_subnet.id]
  aks_version                 = local.aks.aks_version
  aks_sku_tier                = local.aks.aks_sku_tier
  aks_vnet_id                  = data.azurerm_virtual_network.aks_vnet.id
  aks_workload_subnet_ids      = [data.azurerm_subnet.workload_subnet.id]
  aks_workload_pods_subnet_ids = [data.azurerm_subnet.workload_pods_subnet.id]
  aks_nodepools_config         = local.aks.aks_nodepools_config
  aks_system_nodes_config      = local.aks.aks_system_nodes_config
  appgw_subnet_id              = data.azurerm_subnet.appgw_subnet.id
  appgw_private_ip_address     = local.aks.appgw_private_ip_address
  availability_zones           = local.aks.availability_zones

}
