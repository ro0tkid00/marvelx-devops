output "cluster_name" {
  value = kind_cluster.this.name
}

output "internal_endpoint" {
  description = "API server address reachable from containers on the shared Docker network"
  value       = "https://${kind_cluster.this.name}-control-plane:6443"
}

output "kubeconfig" {
  value     = kind_cluster.this.kubeconfig
  sensitive = true
}
