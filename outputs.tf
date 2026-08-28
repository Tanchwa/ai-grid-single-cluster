output "lb_controller_role_arn" {
  description = "IRSA role ARN for the AWS Load Balancer Controller."
  value       = module.cluster_controlplane_nodes.lb_controller_role_arn
}

output "kubeconfig_raw" {
  description = "Raw kubeconfig for the Talos cluster. Requires Tailscale connected to reach the internal API LB."
  sensitive   = true
  value       = talos_cluster_kubeconfig.this.kubeconfig_raw
}

output "talosconfig" {
  description = "Talosconfig for cluster access via Tailscale."
  sensitive   = true
  value       = data.talos_client_configuration.this.talos_config
}
