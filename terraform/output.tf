output "aws_vpcs" {
  value = { for k, v in aws_vpc.vpcs : k => v.cidr_block }
}
output "aws_ec2_public_ips" {
  value = { for k, v in aws_instance.ec2s : k => v.public_ip if v.public_ip != ""}
}
output "aws_ec2_private_ip" {
  value = { for k, v in aws_instance.ec2s : k => v.private_ip }
}
output "aws_eks_clusters" {
  value = { for k, v in aws_eks_cluster.eks_cluster : k => v.name }
}
output "aws_public_dns" {
  value = { for k, v in aws_route53_record.ec2_public_dns : k => "${v.name}.${data.aws_route53_zone.zone.name}" }
}
output "aws_private_dns" {
  value = { for k, v in aws_route53_record.ec2_private_dns : k => "${v.name}.${data.aws_route53_zone.zone.name}" }
}
output "aws_rds_instances" {
    value = { for k, v in aws_db_instance.db_instances : k => v.endpoint }
}
output "azure_vm_private_ip" {
  value = { for k, v in azurerm_network_interface.vminterfaces : k => v.private_ip_address }
}
output "azure_vm_public_ip" {
  value = { for k, v in azurerm_public_ip.public_ip : k => v.ip_address }
}
output "azure_private_dns" {
  value = { for k, v in aws_route53_record.azure_vm_private_dns : k => "${v.name}.${data.aws_route53_zone.zone.name}" }
}
output "azure_public_dns" {
  value = { for k, v in aws_route53_record.azure_vm_public_dns : k => "${v.name}.${data.aws_route53_zone.zone.name}" }
}
output "azure_aks_clusters" {
  value = { for k, v in azurerm_kubernetes_cluster.aks : k => v.name }
}