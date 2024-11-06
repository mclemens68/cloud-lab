resource "aws_route_table" "private" {
  for_each = local.aws_config.vpcs
  vpc_id   = aws_vpc.vpcs[each.key].id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.ngws[each.key].id
  }

  route {
    cidr_block         = "192.168.0.0/16"
    transit_gateway_id = aws_ec2_transit_gateway.tgw.id
  }
  
  tags = {
    Name = "${each.key}-private-rt"
  }
}

resource "aws_route_table" "public" {
  for_each = local.aws_config.vpcs
  vpc_id   = aws_vpc.vpcs[each.key].id
  tags = {
    Name = "${each.key}-public-rt"
  }
}

resource "aws_route" "vgw" {
  for_each = local.azure_config.vpnConnections
  route_table_id            = aws_route_table.public[each.value["awsVPC"]].id
  destination_cidr_block    = each.value["azureNetwork"]
  gateway_id                = aws_vpn_gateway.azurevpn[each.key].id
}

resource "aws_route" "igw" {
  for_each = local.aws_config.vpcs
  route_table_id            = aws_route_table.public[each.key].id
  destination_cidr_block    = "0.0.0.0/0"
  gateway_id = aws_internet_gateway.igws[each.key].id
}

resource "aws_route" "tgw" {
  for_each = local.aws_config.vpcs
  route_table_id            = aws_route_table.public[each.key].id
  destination_cidr_block    = "192.168.0.0/16"
  transit_gateway_id = aws_ec2_transit_gateway.tgw.id
  depends_on = [aws_ec2_transit_gateway.tgw, aws_ec2_transit_gateway_vpc_attachment.tgw-attachment]
}

resource "aws_route_table_association" "public_rta" {
  for_each = {
    for subnet in local.vpc_subnets : "${subnet.vpc_name}.${subnet.subnet_key}" => subnet if subnet.public
  }
  subnet_id      = aws_subnet.subnets[each.key].id
  route_table_id = aws_route_table.public[each.value["vpc_name"]].id
}

resource "aws_route_table_association" "private_rta" {
  for_each = {
    for subnet in local.vpc_subnets : "${subnet.vpc_name}.${subnet.subnet_key}" => subnet if subnet.public == false
  }
  subnet_id      = aws_subnet.subnets[each.key].id
  route_table_id = aws_route_table.private[each.value["vpc_name"]].id
}
