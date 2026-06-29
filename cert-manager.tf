# ─── cert-manager IRSA ───────────────────────────────────────────────────────
# cert-manager needs route53:GetChange in addition to the standard external-dns
# permissions, so it gets its own IRSA role separate from external-dns.

data "aws_iam_policy_document" "cert_manager_assume_role" {
  statement {
    effect = "Allow"
    principals {
      type        = "Federated"
      identifiers = [var.oidc_provider_arn]
    }
    actions = ["sts:AssumeRoleWithWebIdentity"]
    condition {
      test     = "StringEquals"
      variable = "${var.oidc_provider_url}:sub"
      values   = ["system:serviceaccount:cert-manager:cert-manager"]
    }
    condition {
      test     = "StringEquals"
      variable = "${var.oidc_provider_url}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "cert_manager" {
  name               = "${var.cluster_name}-cert-manager"
  assume_role_policy = data.aws_iam_policy_document.cert_manager_assume_role.json
}

data "aws_iam_policy_document" "cert_manager_route53" {
  statement {
    effect = "Allow"
    actions = [
      "route53:GetChange",
      "route53:ChangeResourceRecordSets",
    ]
    resources = [
      "arn:aws:route53:::change/*",
      "arn:aws:route53:::hostedzone/*",
    ]
  }
  statement {
    effect = "Allow"
    actions = [
      "route53:ListResourceRecordSets",
      "route53:ListTagsForResource",
    ]
    resources = ["arn:aws:route53:::hostedzone/*"]
  }
  # ListHostedZones is an account-level action with no resource-level support
  statement {
    effect    = "Allow"
    actions   = ["route53:ListHostedZones"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "cert_manager" {
  name   = "cert-manager-route53"
  role   = aws_iam_role.cert_manager.id
  policy = data.aws_iam_policy_document.cert_manager_route53.json
}
