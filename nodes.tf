module "cluster_controlplane_nodes" {
  source         = "./modules/talos-node"
  cluster_name   = var.cluster_name
  node_role      = "controlplane"
  instance_count = 3

  vpc_id     = module.vpc.vpc_id
  vpc_cidr   = module.vpc.vpc_cidr_block
  subnet_ids = module.vpc.private_subnets

  ami_id               = var.talos_controlplane_ami
  instance_type        = "t3.medium"
  talos_machine_config = base64encode(data.talos_machine_configuration.controlplane.machine_configuration)

  talos_api_allowed_cidrs = [module.vpc.vpc_cidr_block]
  kube_api_allowed_cidrs  = [module.vpc.vpc_cidr_block]

  cilium_enable_vxlan = true

  peer_security_group_ids = [module.tailscale_gateway.security_group_id]

  create_lb_controller_irsa = true
  create_external_dns_irsa  = true
  oidc_provider_arn         = aws_iam_openid_connect_provider.this.arn
  oidc_provider_url         = local.oidc_provider_url
}

module "cluster_worker_nodes" {
  source         = "./modules/talos-node"
  cluster_name   = var.cluster_name
  node_role      = "worker"
  instance_count = 3
  min_size       = 1
  max_size       = 5

  vpc_id     = module.vpc.vpc_id
  vpc_cidr   = module.vpc.vpc_cidr_block
  subnet_ids = module.vpc.private_subnets

  longhorn_volume_size_gb = 1000

  ami_id               = var.talos_worker_ami
  instance_type        = "g4dn.xlarge"
  talos_machine_config = base64encode(data.talos_machine_configuration.worker.machine_configuration)

  talos_api_allowed_cidrs = [module.vpc.vpc_cidr_block]
  # 0.0.0.0/0: NLB instance target type preserves client source IPs, so the VPC
  # CIDR alone would block internet traffic. NodePorts (30000-32767) are not
  # well-known ports; tighten this to a specific CIDR before any production use.
  nodeport_allowed_cidr   = "0.0.0.0/0"
  cilium_enable_vxlan     = true
  peer_security_group_ids = [module.cluster_controlplane_nodes.security_group_id, module.tailscale_gateway.security_group_id]
}
