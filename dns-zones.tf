# If you disable DNSSEC signing for your hosted zone before the DNS changes have propagated, your domain could become unavailable on the internet. When you remove the DS records, you must wait until the longest TTL for the DS records that you remove has expired before you complete the step to disable DNSSEC signing. Please refer to the Route 53 Developer Guide - Disable DNSSEC for a detailed breakdown on the steps required to disable DNSSEC safely for a hosted zone.
# https://docs.aws.amazon.com/Route53/latest/DeveloperGuide/dns-configuring-dnssec-disable.html
resource "aws_kms_key" "this" {
  provider                 = aws.us_east_1
  description              = "KMS key for signing DNSSEC records in Route53"
  customer_master_key_spec = "ECC_NIST_P256"
  deletion_window_in_days  = 7
  key_usage                = "SIGN_VERIFY"

  policy = jsonencode({
    Statement = [
      {
        Action = [
          "kms:DescribeKey",
          "kms:GetPublicKey",
          "kms:PutKeyPolicy",
          "kms:Sign",
          "kms:Verify",
          "kms:CreateGrant",
        ],
        Effect = "Allow"
        Principal = {
          Service = "dnssec-route53.amazonaws.com"
        }
        Resource = "*"
        Sid      = "Allow Route 53 DNSSEC Service",
      },
      {
        Action = "kms:*"
        Effect = "Allow"
        Principal = {
          AWS = data.aws_caller_identity.current.arn
        }
        Resource = "*"
        Sid      = "Enable IAM User Permissions"
      },
    ]
    Version = "2012-10-17"
  })
}

resource "aws_route53_zone" "this" {
  name = var.domain_name
}

resource "aws_route53_key_signing_key" "this" {
  hosted_zone_id             = aws_route53_zone.this.id
  key_management_service_arn = aws_kms_key.this.arn
  name                       = "dnssec-key-sign"
}

resource "aws_route53_hosted_zone_dnssec" "this" {
  depends_on = [
    aws_route53_key_signing_key.this
  ]
  hosted_zone_id = aws_route53_key_signing_key.this.hosted_zone_id
}

# Route53 query logging — log group must reside in us-east-1 (AWS requirement).
resource "aws_cloudwatch_log_group" "route53_query_logs" {
  # checkov:skip=CKV_AWS_158:this is just a temporary environment. I'm not using an encryption key just for some logs that we're going to blow away in a week.
  name              = "/aws/route53/${var.domain_name}"
  retention_in_days = 365

  provider = aws.us_east_1
}

resource "aws_cloudwatch_log_resource_policy" "route53_query_logs" {
  policy_name = "route53-query-logs"

  policy_document = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "route53.amazonaws.com" }
      Action    = ["logs:CreateLogStream", "logs:PutLogEvents"]
      Resource  = "${aws_cloudwatch_log_group.route53_query_logs.arn}:*"
    }]
  })

  provider = aws.us_east_1
}

resource "aws_route53_query_log" "this" {
  depends_on = [aws_cloudwatch_log_resource_policy.route53_query_logs]

  cloudwatch_log_group_arn = aws_cloudwatch_log_group.route53_query_logs.arn
  zone_id                  = aws_route53_zone.this.zone_id
}
