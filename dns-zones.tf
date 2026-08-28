# ─── Cloudflare DNS for cluster load balancers ───────────────────────────────
# The AWS Load Balancer Controller provisions NLBs for the ArgoCD and ingress
# Services outside Terraform state. We locate each NLB by the additional resource
# tag set through the aws-load-balancer-additional-resource-tags annotation (see
# the notation in argo-values.yaml.tftpl), then point a Cloudflare CNAME at its
# NLB DNS name.
#
# These data lookups must run AFTER the Services exist and the controller has
# reconciled the NLB, so the LB lookups depend on the Helm releases that create
# them. If an NLB has not finished provisioning by the time the data source is
# read, re-run apply once it is up.

# Resolve the zone id from the domain name.
data "cloudflare_zones" "this" {
  name   = var.domain_name
  status = "active"
}

locals {
  cloudflare_zone_id = data.cloudflare_zones.this.result[0].id
}

# The NLBs are provisioned asynchronously by the AWS Load Balancer Controller
# after each Service exists — the Helm release returning does not mean the NLB is
# up and tagged yet. Gate each lookup behind a fixed sleep so the data source is
# read after the controller has had time to reconcile the NLB. If a sleep proves
# too short (e.g. a slow first ArgoCD sync), re-run apply once the NLB is up.
resource "time_sleep" "wait_for_argocd_lb" {
  create_duration = "3m"
  depends_on      = [helm_release.argocd]
}

# Ingress-nginx is delivered by ArgoCD (app-of-apps), so its NLB appears only
# after the first sync completes — later than the bootstrap release returning.
resource "time_sleep" "wait_for_ingress_lb" {
  create_duration = "3m"
  depends_on      = [helm_release.argocd_bootstrap]
}

# ArgoCD NLB — tagged `argocd-cluster=<cluster_name>` in argo-values.yaml.tftpl.
data "aws_lb" "argocd" {
  tags = {
    "argocd-cluster" = var.cluster_name
  }

  depends_on = [time_sleep.wait_for_argocd_lb]
}

# Ingress NLB — same annotation notation as ArgoCD, distinct key so each lookup
# matches exactly one load balancer (identical tags would error on multiple
# matches). The ingress Service must carry:
#   service.beta.kubernetes.io/aws-load-balancer-additional-resource-tags: "ingress-controller-name=<controller-name>"
data "aws_lb" "ingress" {
  tags = {
    "ingress-controller-name" = "ingress-nginx"
  }

  depends_on = [time_sleep.wait_for_ingress_lb]
}

# argo.<domain_name> -> ArgoCD NLB. DNS-only (unproxied): ArgoCD terminates its
# own Let's Encrypt TLS, so the CNAME must resolve straight to the NLB.
resource "cloudflare_dns_record" "argocd" {
  zone_id = local.cloudflare_zone_id
  name    = "argo.${var.domain_name}"
  type    = "CNAME"
  content = data.aws_lb.argocd.dns_name
  ttl     = 300
  proxied = false
}

# *.aws.<domain_name> -> ingress NLB. Wildcard so every app subdomain
# (<app>.aws.<domain_name>) resolves to the ingress NLB and ingress-nginx routes
# by Host header. Note: a wildcard matches exactly one label — it does not cover
# the bare aws.<domain_name> or deeper names like a.b.aws.<domain_name>.
resource "cloudflare_dns_record" "ingress" {
  zone_id = local.cloudflare_zone_id
  name    = "aws.${var.domain_name}"
  type    = "CNAME"
  content = data.aws_lb.ingress.dns_name
  ttl     = 300
  proxied = false
}
