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

  # Gateway API support. `config` is serialised verbatim into the controller's
  # config.yaml, which strict-decodes: the key is a flat `enableGatewayAPI`
  # boolean, not a nested block. Requires the gateway.networking.k8s.io CRDs.
  set {
    name  = "config.enableGatewayAPI"
    value = "true"
  }

  timeout = 480

  depends_on = [talos_cluster_kubeconfig.this, helm_release.cilium]
}

# ─── Cloudflare API token for the DNS-01 solver ──────────────────────────────
# The letsencrypt-prod ClusterIssuer (charts/argo-bootstrap) solves DNS-01 via
# Cloudflare. A ClusterIssuer resolves secretRefs in the cert-manager controller's
# own namespace, so the token must live here — not alongside the Certificate.
# Same token as the cloudflare provider: needs Zone:Read + DNS:Edit on the zone.

resource "kubernetes_secret_v1" "cert_manager_cloudflare_api_token" {
  metadata {
    name      = local.cloudflare_api_token_secret_name
    namespace = "cert-manager"
  }

  data = {
    (local.cloudflare_api_token_secret_key) = var.cloudflare_api_token
  }

  type = "Opaque"

  depends_on = [helm_release.cert_manager]
}
