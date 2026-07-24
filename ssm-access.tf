# ─── SSM Session Manager access – Tailscale gateway ─────────────────────────
# Grants the holder permission to open a shell session on the Tailscale gateway
# EC2 instance via AWS Systems Manager. The policy is scoped to the instance tag
# so it remains valid even if the instance is replaced.

data "aws_iam_policy_document" "ssm_tailscale_gateway" {
  # checkov:skip=CKV_AWS_356:failing line is on 47, and is negated by other more detailed lines in the policy statement.
  # Start a session on the Tailscale gateway instance (tag-scoped).
  statement {
    effect  = "Allow"
    actions = ["ssm:StartSession"]
    resources = [
      "arn:aws:ec2:${var.aws_region}:${data.aws_caller_identity.current.account_id}:instance/*",
    ]
    condition {
      test     = "StringEquals"
      variable = "ssm:resourceTag/Name"
      values   = ["tailscale-aws-gateway"]
    }
  }

  # Allow use of the default interactive-shell SSM document.
  statement {
    effect    = "Allow"
    actions   = ["ssm:StartSession"]
    resources = ["arn:aws:ssm:*:*:document/SSM-SessionManagerRunShell"]
  }

  # Allow the caller to terminate or resume their own sessions.
  statement {
    effect  = "Allow"
    actions = ["ssm:TerminateSession", "ssm:ResumeSession"]
    resources = [
      "arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:session/*",
    ]
  }

  # Read-only: list SSM-registered instances and check connection status.
  statement {
    effect = "Allow"
    actions = [
      "ssm:DescribeSessions",
      "ssm:GetConnectionStatus",
      "ssm:DescribeInstanceInformation",
      "ssm:DescribeInstanceProperties",
      "ec2:DescribeInstances",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "ssm_tailscale_gateway" {
  name        = "${var.cluster_name}-ssm-tailscale-gateway"
  description = "SSM Session Manager access scoped to the Tailscale gateway EC2 instance."
  policy      = data.aws_iam_policy_document.ssm_tailscale_gateway.json
}

resource "aws_iam_role" "ssm_tailscale_gateway" {
  name        = "${var.cluster_name}-ssm-tailscale-gateway"
  description = "Assume this role to open an SSM shell session on the Tailscale gateway."

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { AWS = data.aws_caller_identity.current.arn }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = {
    Name = "${var.cluster_name}-ssm-tailscale-gateway"
  }
}

resource "aws_iam_role_policy_attachment" "ssm_tailscale_gateway" {
  role       = aws_iam_role.ssm_tailscale_gateway.name
  policy_arn = aws_iam_policy.ssm_tailscale_gateway.arn
}

output "ssm_tailscale_gateway_role_arn" {
  description = "Assume this role to get SSM Session Manager access to the Tailscale gateway. Usage: aws sts assume-role --role-arn <ARN> --role-session-name ssm-session"
  value       = aws_iam_role.ssm_tailscale_gateway.arn
}
