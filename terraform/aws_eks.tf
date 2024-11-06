resource "aws_eks_cluster" "eks_cluster" {
  for_each = local.aws_config.eksClusters
  name     = each.key
  role_arn = aws_iam_role.role.arn
  vpc_config {
    subnet_ids = [for subnetName in each.value["subnets"] : aws_subnet.subnets[subnetName].id]
    // To-do use the subnets listed in the config file.
  }
}

resource "aws_eks_node_group" "eks_cluster_nodegroup" {
  for_each = local.aws_config.eksClusters
  cluster_name    = aws_eks_cluster.eks_cluster[each.key].name
  node_group_name = "${each.key}-nodegroup"
  node_role_arn   = aws_iam_role.role.arn
  subnet_ids = [for subnetName  in each.value["subnets"] : aws_subnet.subnets[subnetName].id]

  scaling_config {
    desired_size = 3
    max_size     = 3
    min_size     = 3
  }

}
