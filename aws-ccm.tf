# ─── AWS Cloud Controller Manager ────────────────────────────────────────────
# Sets spec.providerID on each Kubernetes node (required by the AWS LB
# controller to resolve node → EC2 instance for target group registration).

data "aws_iam_policy_document" "aws_ccm_assume_role" {
  statement {
    effect = "Allow"
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.this.arn]
    }
    actions = ["sts:AssumeRoleWithWebIdentity"]
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_provider_url}:sub"
      values   = ["system:serviceaccount:kube-system:cloud-controller-manager"]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_provider_url}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "aws_ccm" {
  name               = "${var.cluster_name}-aws-ccm"
  assume_role_policy = data.aws_iam_policy_document.aws_ccm_assume_role.json
}

data "aws_iam_policy_document" "aws_ccm" {
  statement {
    effect = "Allow"
    actions = [
      "autoscaling:DescribeAutoScalingGroups",
      "autoscaling:DescribeLaunchConfigurations",
      "autoscaling:DescribeTags",
      "ec2:DescribeAvailabilityZones",
      "ec2:DescribeInstances",
      "ec2:DescribeImages",
      "ec2:DescribeRegions",
      "ec2:DescribeRouteTables",
      "ec2:DescribeSecurityGroups",
      "ec2:DescribeSubnets",
      "ec2:DescribeVolumes",
      "ec2:DescribeVpcs",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "aws_ccm" {
  name   = "aws-ccm"
  role   = aws_iam_role.aws_ccm.id
  policy = data.aws_iam_policy_document.aws_ccm.json
}

resource "helm_release" "aws_ccm" {
  name             = "aws-cloud-controller-manager"
  repository       = "https://kubernetes.github.io/cloud-provider-aws"
  chart            = "aws-cloud-controller-manager"
  version          = "0.0.9"
  namespace        = "kube-system"
  create_namespace = false

  values = [yamlencode({
    args = [
      "--v=2",
      "--cloud-provider=aws",
      "--cluster-name=${var.cluster_name}",
      "--use-service-account-credentials=true",
    ]
    serviceAccount = {
      annotations = {
        "eks.amazonaws.com/role-arn" = aws_iam_role.aws_ccm.arn
      }
    }
    # Provide region directly so the CCM doesn't need to hit IMDS for bootstrapping.
    env = [
      { name = "AWS_REGION", value = var.aws_region },
      { name = "AWS_DEFAULT_REGION", value = var.aws_region },
    ]
    tolerations = [
      {
        key      = "node-role.kubernetes.io/control-plane"
        operator = "Exists"
        effect   = "NoSchedule"
      },
      {
        # Tolerate uninitialized nodes so CCM can bootstrap them.
        key      = "node.cloudprovider.kubernetes.io/uninitialized"
        operator = "Exists"
        effect   = "NoSchedule"
      },
    ]
  })]

  depends_on = [talos_cluster_kubeconfig.this, helm_release.pod_identity_webhook]
}
