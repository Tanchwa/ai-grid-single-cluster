locals {
  # Carve 6 equal subnets from the VPC CIDR: first 3 are private, next 3 are public.
  _all_subnet_cidrs   = cidrsubnets(var.global_network_space, 8, 8, 8, 8, 8, 8)
  subnet_cidrs        = slice(local._all_subnet_cidrs, 0, 3)
  public_subnet_cidrs = slice(local._all_subnet_cidrs, 3, 6)

  # First controlplane IP — the single node talosctl bootstraps etcd on.
  cluster_bootstrap_ip = module.cluster_controlplane_nodes.instance_private_ips[0]
}

# Cloudflare API token Secret — same name/key in both the cert-manager and
# external-dns namespaces so the ClusterIssuer and the external-dns env var
# reference a single pair of constants.
locals {
  cloudflare_api_token_secret_name = "cloudflare-api-token" # pragma: allowlist secret
  cloudflare_api_token_secret_key  = "api-token"            # pragma: allowlist secret
}
