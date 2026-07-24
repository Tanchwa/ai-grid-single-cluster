# ─── cert-manager ────────────────────────────────────────────────────────────

resource "helm_release" "cert_manager" {
  name             = "cert-manager"
  repository       = "https://charts.jetstack.io"
  chart            = "cert-manager"
  version          = "1.17.2"
  namespace        = "cert-manager"
  create_namespace = true
  wait             = true

  set {
    name  = "crds.enabled"
    value = "true"
  }

  timeout = 480

  depends_on = [talos_cluster_kubeconfig.this, helm_release.cilium]
}
