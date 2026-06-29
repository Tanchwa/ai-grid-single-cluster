module "vpc" {
  source = "git::https://github.com/terraform-aws-modules/terraform-aws-vpc?ref=3ffbd46fb1c7733e1b34d8666893280454e27436"

  name = "${var.cluster_name}-vpc"
  cidr = var.global_network_space

  azs             = ["ap-east-2a", "ap-east-2b", "ap-east-2c"]
  private_subnets = local.subnet_cidrs
  public_subnets  = local.public_subnet_cidrs

  # Single NAT gateway per VPC — nodes need internet egress to pull container images.
  enable_nat_gateway = true
  single_nat_gateway = true

  enable_dns_hostnames = true
  enable_dns_support   = true

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb"           = 1
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  }

  public_subnet_tags = {
    "kubernetes.io/role/elb"                    = 1
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  }
}
