locals {
  config = yamldecode(file("../config/${var.dtap_environment}.yml"))
  aks    = local.config["aks"]
  naming = local.config["naming"]
  mgmt   = local.config["mgmt"]
  
}
