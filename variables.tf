variable "global_network_space" {
  description = "The CIDR block for the VPC. Subnets are carved from this block."
  type        = string
  default     = ""
}

variable "aws_region" {
  description = "Region for the cluster and supporting resources to be deployed in"
  type        = string
  default     = "ap-east-2"
}

variable "aws_profile" {
  description = "AWS profile to use for authentication. If not set, the default profile will be used."
  type        = string
  default     = "default"
}

variable "cluster_name" {
  description = "Kubernetes cluster name. Used in kubernetes.io/cluster/* tags on VPC subnets and EC2 nodes."
  type        = string
}

variable "domain_name" {
  description = "Root DNS domain managed by Route 53 and filtered by external-dns (e.g. example.com)."
  type        = string
}

variable "cloudflare_api_token" {
  description = "Cloudflare API token used by the cloudflare provider to manage DNS records in the domain_name zone. Needs Zone:Read and DNS:Edit on the zone."
  type        = string
  sensitive   = true
}

variable "talos_worker_ami" {
  description = "Talos AMI to use in EC2 worker instances."
  type        = string
}

variable "talos_controlplane_ami" {
  description = "Talos AMI to use in EC2 controlplane instances."
  type        = string
}

variable "talos_version" {
  description = "Version for Talos initiation."
  type        = string
  default     = ""
}

variable "kubernetes_version" {
  description = "Kubernetes install version. Must be a full patch version (e.g. v1.36.3) matching an available kubelet image tag."
  type        = string
  default     = ""
}

variable "scheduler_extender_url" {
  description = "Kubernetes service name for the custom scheduler extender plugin, resolved within kube-system. Injected into scheduler-config.yaml on controlplane nodes."
  type        = string
  default     = ""
}

# ─── ArgoCD OIDC (Azure Entra ID) ────────────────────────────────────────────

variable "argocd_oidc_issuer" {
  description = "OIDC issuer URL for ArgoCD login. For Azure Entra ID use the v2.0 endpoint: https://login.microsoftonline.com/<tenant-id>/v2.0"
  type        = string
  default     = ""
}

variable "argocd_oidc_client_id" {
  description = "OIDC client ID for ArgoCD — the Application (client) ID of the Entra app registration."
  type        = string
  default     = ""
}

variable "argocd_oidc_client_secret" {
  description = "OIDC client secret for ArgoCD — a client secret on the Entra app registration. Injected into argocd-secret; never stored in plain text in state."
  type        = string
  sensitive   = true
}

variable "letsencrypt_email" {
  description = "Email address for Let's Encrypt ACME account registration and certificate expiry notifications."
  type        = string
}

# ─── GitHub App (ArgoCD repository authentication) ───────────────────────────

variable "github_app_of_apps_repo_name" {
  description = "GitHub repository in org/repo format used as the ArgoCD App-of-Apps source (e.g. my-org/argocd-core)."
  type        = string
  default     = ""
}

variable "github_organization_name" {
  description = "GitHub organization used as the core secret for all app of apps sub sources."
  type        = string
  default     = ""
}


variable "github_application_id" {
  description = "GitHub App ID for ArgoCD repository authentication."
  type        = string
}

variable "github_application_installation_id" {
  description = "GitHub App Installation ID for ArgoCD repository authentication."
  type        = string
}

locals {
  _github_application_private_key = file("~/Downloads/for-argocd-poc.2026-07-20.private-key.pem")
}

#variable "github_application_private_key" {
#  description = "GitHub App private key in PEM format for ArgoCD repository authentication."
#  type        = string
#  sensitive   = true
#}

variable "domain_registrant" {
  description = "Contact information for domain registration (used for registrant, admin, and tech contacts)."
  type = object({
    first_name     = string
    last_name      = string
    email          = string
    phone_number   = string # E.164 format: +1.2025551234
    address_line_1 = string
    city           = string
    state          = string # e.g. "WA"; required for US
    country_code   = string # ISO 3166-1 alpha-2: e.g. "US"
    zip_code       = string
  })
  default = {
    first_name     = "First"
    last_name      = "Last"
    email          = "email@example.com"
    phone_number   = "+1.2025551234"
    address_line_1 = "123 Main St"
    city           = "Seattle"
    state          = "WA"
    country_code   = "US"
    zip_code       = "98101"
  }
}

variable "tailscale_auth_key" {
  description = "Tailscale auth key (reusable, ephemeral, or pre-authorized) used to join the gateway EC2 instance to your tailnet."
  type        = string
  sensitive   = true
}

# ─── Cilium ──────────────────────────────────────────────────────────────────

variable "cilium_version" {
  description = "Cilium Helm chart version to install."
  type        = string
  default     = "1.17.3"
}

variable "cilium_pod_cidr" {
  description = "Pod CIDR for Cilium's cluster-pool IPAM. Must not overlap with the VPC CIDR (global_network_space)."
  type        = string
  default     = "10.244.0.0/16"
}

variable "cilium_bgp_enabled" {
  description = "Enable Cilium BGP Control Plane and route advertisement. Actual peering requires CiliumBGPPeeringPolicy or CiliumBGPClusterConfig resources; safe to enable alongside AWS Load Balancer Controller."
  type        = bool
  default     = true
}
