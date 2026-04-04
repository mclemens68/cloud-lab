module "rosa" {
  source = "./modules/rosa"
  count  = length(local.aws_config.rosaClusters) > 0 ? 1 : 0

  rosa_clusters = local.aws_config.rosaClusters
  region        = local.aws_config.region

  subnets = {
    for key, subnet in local.aws_subnets : key => {
      id                = subnet.id
      availability_zone = subnet.availability_zone
    }
  }
}
