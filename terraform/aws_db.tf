resource "aws_db_subnet_group" "db_subnet_groups" {
  for_each   = { for k, v in local.aws_config.vpcs : k => v if v.dbGroup }
  name       = each.key
  subnet_ids = [for subnetName, v in local.aws_config.vpcs[each.key].subnets : aws_subnet.subnets["${each.key}.${subnetName}"].id if v.public == false] 
}

resource "aws_db_instance" "db_instances" {
  for_each               = local.aws_config.rdsInstances
  db_subnet_group_name   = aws_db_subnet_group.db_subnet_groups[each.value["vpc"]].name
  allocated_storage      = 10
  db_name                = each.key
  identifier             = each.key
  engine                 = each.value["engine"]
  engine_version         = each.value["engineVersion"]
  instance_class         = each.value["instanceClass"]
  password               = "dbPassword123" # This is for demo purposes only with no real data
  username               = "dbadmin"       # This is for demo purposes only with no real data
  vpc_security_group_ids = [aws_security_group.base[each.value["vpc"]].id]
  skip_final_snapshot    = true
}
