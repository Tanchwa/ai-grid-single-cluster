output "external_dns_role_arn" {
  description = "Annotate the external-dns ServiceAccount with this ARN."
  value       = module.cluster_controlplane_nodes.external_dns_role_arn
}

output "lb_controller_role_arn" {
  description = "IRSA role ARN for the AWS Load Balancer Controller."
  value       = module.cluster_controlplane_nodes.lb_controller_role_arn
}

output "cert_manager_role_arn" {
  description = "IRSA role ARN used by cert-manager for Route53 DNS-01 challenges."
  value       = aws_iam_role.cert_manager.arn
}

output "argocd_url" {
  description = "Public HTTPS URL for the ArgoCD UI. NLB DNS name is managed by external-dns."
  value       = "https://argocd.${var.domain_name}"
}
