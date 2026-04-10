// Create VPC endpoints
resource "aws_vpc_endpoint" "endpoints" {
  for_each          = { for idx, ep in try(local.vpc_endpoints, []) : "${ep.vpc_name}-${ep.endpoint_name}" => ep }
  vpc_id            = each.value.vpc_id
  service_name      = each.value.service_name
  route_table_ids   = each.value.route_table_ids
  vpc_endpoint_type = "Gateway"
  tags = {
    Name = "${each.value.vpc_name}-${each.value.endpoint_name}-endpoint"
  }
}