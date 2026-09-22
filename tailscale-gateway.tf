module "tailscale_gateway" {
  source = "../../../terraform-aws-tailscale-gateway"

  network = {
    vpc_id                   = module.vpc.vpc_id
    tailscale_subnet_id      = module.vpc.private_subnets[0]
    dns_resolver_subnet_id_1 = module.vpc.private_subnets[0]
    dns_resolver_subnet_id_2 = module.vpc.private_subnets[1]
  }

  # Advertise all private subnets so both the internal k8s API LB and all node
  # IPs are reachable over Tailscale.
  subnets_to_advertise = toset(local.subnet_cidrs)

  tailscale_auth_key = var.tailscale_auth_key
}

# Egress to the tailnet: send tailnet-bound traffic from the private subnets
# through the gateway ENI instead of the NAT gateway. 100.64.0.0/10 is CGNAT
# space and unroutable on the internet, so without this it dies at the NAT.
# Cilium masquerades pod traffic to the node IP, so packets reach the VPC
# router as ordinary private-subnet traffic and need no pod-CIDR route.
resource "aws_route" "tailnet_egress" {
  for_each = toset(module.vpc.private_route_table_ids)

  route_table_id         = each.value
  destination_cidr_block = var.tailnet_cidr
  network_interface_id   = module.tailscale_gateway.network_interface_id
}

output "tailscale_gateway_info" {
  description = "Post-deploy DNS forwarding instructions for the Tailscale gateway."
  value       = module.tailscale_gateway.additional_info
}
