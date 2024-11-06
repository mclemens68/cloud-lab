// Each VPC gets an internet gateway
resource "aws_internet_gateway" "igws" {
  for_each = local.aws_config.vpcs
  vpc_id   = aws_vpc.vpcs[each.key].id
  tags = {
    Name = "${each.key}.igw"
  }
}

// Each VPC gets an elastic IP for the nat gateway
resource "aws_eip" "ngw_eips" {
  for_each = local.aws_config.vpcs
  domain   = "vpc"
  tags = {
    Name = "${each.key}-ngw-eip"
  }
}

// Every public subnet gets a nat gateway - logic assumes only 1 public subnet per VPC
resource "aws_nat_gateway" "ngws" {
  for_each = {
    for subnet in local.vpc_subnets : subnet.vpc_name => subnet if subnet.public
  }
  connectivity_type = "public"
  allocation_id     = aws_eip.ngw_eips[each.value["vpc_name"]].id
  subnet_id         = aws_subnet.subnets[each.value["subnet_name"]].id
  depends_on        = [aws_internet_gateway.igws]
  tags = {
    Name = "${each.value["subnet_name"]}-ngw"
  }
}

// Create 1 transit gateways to connect all the VPCs
resource "aws_ec2_transit_gateway" "tgw" {
  description                    = "transit gateway to connect vpcs"
  dns_support                    = "enable"
  vpn_ecmp_support               = "enable"
  auto_accept_shared_attachments = "enable"
  tags = {
    Name = replace(replace("config-files/${terraform.workspace}-aws.yaml-tgw", "-",""),"_","")
  }
}

// Attach the transit gateway to all subnets in the VPC
resource "aws_ec2_transit_gateway_vpc_attachment" "tgw-attachment" {
  for_each           = local.aws_config.vpcs
  transit_gateway_id = aws_ec2_transit_gateway.tgw.id
  vpc_id             = aws_vpc.vpcs[each.key].id
  subnet_ids         = [for subnetName, v in local.aws_config.vpcs[each.key].subnets : aws_subnet.subnets["${each.key}.${subnetName}"].id]
}

resource "aws_customer_gateway" "azurevpn" {
  for_each = local.azure_config.vpnConnections
  bgp_asn    = 65000
  ip_address = azurerm_public_ip.vgw_pip[each.key].ip_address
  type       = "ipsec.1"

  tags = {
    Name = "azure-vpn-cgw"
  }
}

resource "aws_vpn_gateway" "azurevpn" {
  for_each = local.azure_config.vpnConnections
  vpc_id = aws_vpc.vpcs[each.value["awsVPC"]].id
  tags = {
    Name = "azure-vpn-gw"
  }
}

resource "aws_vpn_connection" "azurevpn" {
  for_each = local.azure_config.vpnConnections
  customer_gateway_id = aws_customer_gateway.azurevpn[each.key].id
  vpn_gateway_id = aws_vpn_gateway.azurevpn[each.key].id
  type = aws_customer_gateway.azurevpn[each.key].type
  static_routes_only = true
  
}

resource "aws_vpn_connection_route" "azurevpn" {
  for_each = local.azure_config.vpnConnections
  destination_cidr_block = each.value["azureNetwork"]
  vpn_connection_id      = aws_vpn_connection.azurevpn[each.key].id
}
