# ─── Node IAM role & instance profile ───────────────────────────────────────

resource "aws_iam_role" "nodes" {
  count = var.create_iam_resources ? 1 : 0

  name = "${var.cluster_name}-${var.node_role}-node"
  path = "/"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = merge(local.common_tags, {
    Name = "${var.cluster_name}-${var.node_role}-node"
  })
}

# Minimal EC2 describe permissions needed by kubelet and the external AWS CCM
# for node registration, zone/subnet discovery, and route management.
resource "aws_iam_role_policy" "node_ec2_describe" {
  count = var.create_iam_resources ? 1 : 0

  name = "${var.cluster_name}-${var.node_role}-ec2-describe"
  role = aws_iam_role.nodes[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ec2:DescribeInstances",
          "ec2:DescribeInstanceTypes",
          "ec2:DescribeRegions",
          "ec2:DescribeRouteTables",
          "ec2:DescribeSecurityGroups",
          "ec2:DescribeSubnets",
          "ec2:DescribeVolumes",
          "ec2:DescribeAvailabilityZones",
          "ec2:DescribeVpcs",
          "ec2:DescribeInternetGateways",
          "ec2:DescribeNetworkInterfaces",
          "ec2:DescribeTags",
        ]
        Resource = "*"
      },
      # CCM on control plane nodes manages VPC routes for pod CIDRs.
      {
        Effect = "Allow"
        Action = [
          "ec2:CreateRoute",
          "ec2:DeleteRoute",
          "ec2:ModifyInstanceAttribute",
          "ec2:CreateTags",
          "ec2:DeleteTags",
        ]
        Resource = "*"
        Condition = {
          StringEquals = {
            "aws:ResourceTag/kubernetes.io/cluster/${var.cluster_name}" = ["owned", "shared"]
          }
        }
      },
    ]
  })
}

# ECR pull access – needed on all nodes (no public internet in this VPC; pulls via VPC endpoint).
resource "aws_iam_role_policy" "node_ecr" {
  count = var.create_iam_resources ? 1 : 0

  name = "${var.cluster_name}-${var.node_role}-ecr"
  role = aws_iam_role.nodes[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # ecr:GetAuthorizationToken is account-level and cannot be scoped to a resource ARN.
        Effect   = "Allow"
        Action   = ["ecr:GetAuthorizationToken"]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:GetDownloadUrlForLayer",
          "ecr:GetRepositoryPolicy",
          "ecr:DescribeRepositories",
          "ecr:ListImages",
          "ecr:BatchGetImage",
          "ecr:DescribeImages",
        ]
        Resource = "arn:aws:ecr:*:*:repository/*"
      },
    ]
  })
}

resource "aws_iam_instance_profile" "nodes" {
  count = var.create_iam_resources ? 1 : 0

  name = "${var.cluster_name}-${var.node_role}-node"
  role = aws_iam_role.nodes[0].name

  tags = local.common_tags
}

# ─── AWS Load Balancer Controller – IRSA ────────────────────────────────────
# Enable on exactly one module instance per cluster (typically the control plane group).
# The policy document (lb_controller_iam_policy.json) is the official AWS-published policy.

resource "aws_iam_role" "lb_controller" {
  count = var.create_lb_controller_irsa ? 1 : 0

  name = "${var.cluster_name}-aws-lb-controller"
  path = "/"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = var.oidc_provider_arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${var.oidc_provider_url}:sub" = "system:serviceaccount:${var.lb_controller_namespace}:${var.lb_controller_service_account}"
          "${var.oidc_provider_url}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })

  tags = merge(local.common_tags, {
    Name = "${var.cluster_name}-aws-lb-controller"
  })
}

resource "aws_iam_role_policy" "lb_controller" {
  count = var.create_lb_controller_irsa ? 1 : 0

  name   = "${var.cluster_name}-aws-lb-controller"
  role   = aws_iam_role.lb_controller[0].id
  policy = file("${path.module}/lb_controller_iam_policy.json")
}

# ─── External-DNS – IRSA ─────────────────────────────────────────────────────
# Enable on exactly one module instance per cluster (typically the control plane group).

resource "aws_iam_role" "external_dns" {
  count = var.create_external_dns_irsa ? 1 : 0

  name = "${var.cluster_name}-external-dns"
  path = "/"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = var.oidc_provider_arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${var.oidc_provider_url}:sub" = "system:serviceaccount:${var.external_dns_namespace}:${var.external_dns_service_account}"
          "${var.oidc_provider_url}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })

  tags = merge(local.common_tags, {
    Name = "${var.cluster_name}-external-dns"
  })
}

resource "aws_iam_role_policy" "external_dns" {
  count = var.create_external_dns_irsa ? 1 : 0

  name = "${var.cluster_name}-external-dns"
  role = aws_iam_role.external_dns[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["route53:ChangeResourceRecordSets"]
        Resource = "arn:aws:route53:::hostedzone/*"
      },
      {
        # route53:ListHostedZones is account-level and cannot be scoped to a resource ARN.
        Effect   = "Allow"
        Action   = ["route53:ListHostedZones"]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "route53:ListResourceRecordSets",
          "route53:ListTagsForResource",
        ]
        Resource = "arn:aws:route53:::hostedzone/*"
      },
    ]
  })
}
