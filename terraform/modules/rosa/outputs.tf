output "cluster_ids" {
  value = { for k, v in rhcs_cluster_rosa_hcp.rosa_clusters : k => v.id }
}

output "api_urls" {
  value = { for k, v in rhcs_cluster_rosa_hcp.rosa_clusters : k => v.api_url }
}

output "console_urls" {
  value = { for k, v in rhcs_cluster_rosa_hcp.rosa_clusters : k => v.console_url }
}
