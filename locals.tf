locals {
  # Carve 6 equal subnets from the VPC CIDR: first 3 are private, next 3 are public.
  _all_subnet_cidrs   = cidrsubnets(var.global_network_space, 8, 8, 8, 8, 8, 8)
  subnet_cidrs        = slice(local._all_subnet_cidrs, 0, 3)
  public_subnet_cidrs = slice(local._all_subnet_cidrs, 3, 6)

  # First controlplane IP — the single node talosctl bootstraps etcd on.
  cluster_bootstrap_ip = module.cluster_controlplane_nodes.instance_private_ips[0]
}
