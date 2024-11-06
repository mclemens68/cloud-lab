resource "aws_ec2_managed_prefix_list" "rfc1918" {
  name           = "rfc1918"
  address_family = "IPv4"
  max_entries    = 3

  entry {
    cidr = "10.0.0.0/8"
  }
  entry {
    cidr = "172.16.0.0/12"
  }
  entry {
    cidr = "192.168.0.0/16"
  }
}

resource "aws_ec2_managed_prefix_list" "admin" {
  name           = "admin"
  address_family = "IPv4"
  max_entries    = length(local.aws_config.admin_cidr_list)

  dynamic "entry" {
    for_each = local.aws_config.admin_cidr_list

    content {
      cidr = entry.value
    }
  }
}

resource "aws_security_group" "base" {
  for_each    = local.aws_config.vpcs
  name        = "${each.key}-base"
  description = "default rules for lab workloads"
  vpc_id      = aws_vpc.vpcs[each.key].id

  dynamic "ingress" {
    for_each = local.aws_config.allowedPorts.private
    content {
      from_port       = ingress.value
      to_port         = ingress.value
      protocol        = "tcp"
      prefix_list_ids = [aws_ec2_managed_prefix_list.rfc1918.id, aws_ec2_managed_prefix_list.admin.id]
    }
  }

  dynamic "ingress" {
    for_each = local.aws_config.allowedPorts.public
    content {
      from_port   = ingress.value
      to_port     = ingress.value
      protocol    = "tcp"
      cidr_blocks = ["0.0.0.0/0"]
    }
  }

  // Allow outbound all
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = -1
    cidr_blocks = ["0.0.0.0/0"]
  }
}
