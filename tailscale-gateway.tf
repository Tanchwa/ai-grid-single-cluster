module "tailscale_gateway" {
  source = "../../../terraform-aws-tailscale-gateway"

  network = {
    vpc_id                 = module.vpc.vpc_id
    tailscale_subnet_id    = module.vpc.private_subnets[0]
    dns_resolver_subnet_id = module.vpc.private_subnets[1]
  }

  # Advertise all private subnets so both the internal k8s API LB and all node
  # IPs are reachable over Tailscale.
  subnets_to_advertise = toset(module.vpc.private_subnets)

  tailscale_auth_key = var.tailscale_auth_key
}

output "tailscale_gateway_info" {
  description = "Post-deploy DNS forwarding instructions for the Tailscale gateway."
  value       = module.tailscale_gateway.additional_info
}
