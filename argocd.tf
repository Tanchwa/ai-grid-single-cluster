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
    file("${path.module}/argo-values.yaml"),
    templatefile("${path.module}/argo-values-dex.yaml.tftpl", {
      domain_name           = var.domain_name
      argocd_oidc_issuer    = var.argocd_oidc_issuer
      argocd_oidc_client_id = var.argocd_oidc_client_id
      public_subnets        = join(",", module.vpc.public_subnets)
    }),
  ]

  # OIDC client secret stored in argocd-secret via ArgoCD's $dex.oidcClientSecret substitution.
  set_sensitive {
    name  = "configs.secret.extra.dex\\.oidcClientSecret"
    value = var.argocd_oidc_client_secret
  }

  depends_on = [helm_release.lb_controller]
}

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
      githubApplicationPrivateKey     = var.github_application_private_key
      letsencryptEmail                = var.letsencrypt_email
      route53ZoneId                   = aws_route53_zone.this.zone_id
      argocdDomain                    = "argocd.${var.domain_name}"
    }))
  ]

  depends_on = [helm_release.argocd]
}
