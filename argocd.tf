# ─── ArgoCD ──────────────────────────────────────────────────────────────────

resource "helm_release" "argocd" {
  name             = "argo"
  repository       = "oci://ghcr.io/argoproj/argo-helm"
  chart            = "argo-cd"
  version          = "9.2.3"
  namespace        = "argocd"
  create_namespace = true
  wait             = true

  values = [
    templatefile("${path.module}/argo-values.yaml.tftpl", {
      cluster_name          = var.cluster_name
      argocd_oidc_issuer    = var.argocd_oidc_issuer
      argocd_oidc_client_id = var.argocd_oidc_client_id
      public_subnets        = join(",", module.vpc.public_subnets)
    }),
  ]

  # OIDC client secret stored in argocd-secret via ArgoCD's $oidc.keycloak.clientSecret substitution.
  set_sensitive {
    name  = "configs.secret.extra.oidc\\.keycloak\\.clientSecret"
    value = var.argocd_oidc_client_secret
  }

  depends_on = [talos_cluster_kubeconfig.this, helm_release.lb_controller]
}

#resource "time_sleep" "wait_argo_lb" {
#  create_duration = "1m"
#  depends_on      = [helm_release.argocd]
#}
#
#data "aws_lb" "argocd" {
#  tags = {
#    argocd-cluster = var.cluster_name
#  }
#
#  depends_on = [time_sleep.wait_argo_lb]
#}

# ─── ArgoCD App-of-Apps bootstrap ────────────────────────────────────────────

resource "helm_release" "argocd_bootstrap" {
  name      = "argo-app-of-apps-bootstrap"
  chart     = "${path.module}/charts/argo-bootstrap"
  namespace = "argocd"

  values = [
    sensitive(jsonencode({
      githubRepositoryName            = var.github_repository_name
      githubApplicationId             = var.github_application_id
      githubApplicationInstallationId = var.github_application_installation_id
      githubApplicationPrivateKey     = local._github_application_private_key
    }))
  ]

  depends_on = [talos_cluster_kubeconfig.this, helm_release.argocd]
}
