# ─── external-dns (Cloudflare) ───────────────────────────────────────────────
# Watches Services and Ingresses and syncs their hostnames into the Cloudflare
# zone for var.domain_name. Records are created from the usual hints:
#   Ingress          -> spec.rules[].host
#   Service (LB)     -> external-dns.alpha.kubernetes.io/hostname annotation
#
# Cloudflare — not Route 53 — is the authority for this zone, so external-dns
# authenticates with the same API token as the cloudflare provider and
# cert-manager rather than the Route 53 IRSA role in modules/talos-node.

resource "kubernetes_namespace_v1" "external_dns" {
  metadata {
    name = "external-dns"
  }

  depends_on = [talos_cluster_kubeconfig.this, helm_release.cilium]
}

resource "kubernetes_secret_v1" "external_dns_cloudflare_api_token" {
  metadata {
    name      = local.cloudflare_api_token_secret_name
    namespace = kubernetes_namespace_v1.external_dns.metadata[0].name
  }

  data = {
    (local.cloudflare_api_token_secret_key) = var.cloudflare_api_token
  }

  type = "Opaque"
}

resource "helm_release" "external_dns" {
  name             = "external-dns"
  repository       = "https://kubernetes-sigs.github.io/external-dns/"
  chart            = "external-dns"
  version          = "1.22.0"
  namespace        = kubernetes_namespace_v1.external_dns.metadata[0].name
  create_namespace = false
  wait             = true

  values = [
    yamlencode({
      provider = {
        name = "cloudflare"
      }

      # The API token is read from the Secret above; never templated into values
      # (Helm release values land in Terraform state and in the release secret).
      env = [
        {
          name = "CF_API_TOKEN"
          valueFrom = {
            secretKeyRef = {
              name = local.cloudflare_api_token_secret_name
              key  = local.cloudflare_api_token_secret_key
            }
          }
        },
      ]

      sources = ["service", "ingress", "gateway-httproute"]

      # Confine external-dns to the cluster's own zone.
      domainFilters = [var.domain_name]

      # upsert-only: external-dns creates and updates records but never deletes.
      # dns-zones.tf manages argo.<domain> and aws.<domain> in the same zone, so
      # a `sync` policy risks external-dns reaping Terraform-owned records that
      # carry no TXT ownership marker. Switch to `sync` only once every record in
      # the zone is owned by external-dns.
      policy = "upsert-only"

      # TXT registry marks each managed record with this cluster's id, so two
      # clusters sharing the zone cannot clobber each other's records.
      registry   = "txt"
      txtOwnerId = var.cluster_name
      txtPrefix  = "extdns-"

      serviceAccount = {
        create = true
        name   = "external-dns"
      }

      # Records are left unproxied (external-dns's default for Cloudflare), so
      # they resolve straight to the NLB — the ingress and ArgoCD endpoints
      # terminate their own Let's Encrypt TLS. Per-record opt-in to the orange
      # cloud is the external-dns.alpha.kubernetes.io/cloudflare-proxied
      # annotation on the Service or Ingress.
    }),
  ]

  depends_on = [
    talos_cluster_kubeconfig.this,
    kubernetes_secret_v1.external_dns_cloudflare_api_token,
  ]
}
