resource "aws_dynamodb_table" "dynamodb_tables" {
  for_each = try(local.aws_config.dynamoDBTables, {})

  name         = each.value.name
  hash_key     = each.value.hashKey
  billing_mode = "PROVISIONED"

  attribute {
    name = each.value.hashKey
    type = each.value.hashKeyType
  }

  read_capacity  = each.value.readCapacity
  write_capacity = each.value.writeCapacity

  dynamic "attribute" {
    for_each = each.value.attributes
    content {
      name = attribute.value.name
      type = attribute.value.type
    }
  }
}