data "aws_caller_identity" "current" {}

resource "aws_s3_bucket" "lb_logs" {
  # checkov:skip=CKV_AWS_144:cross-region replication not required for access logs
  # checkov:skip=CKV2_AWS_61:lifecycle rules defined in aws_s3_bucket_lifecycle_configuration
  # checkov:skip=CKV2_AWS_62:Event notifications are a bit overkill for now
  # checkov:skip=CKV_AWS_18:No access logging is fine for now. no critical data stored
  # checkov:skip=CKV_AWS_21:we don't really need versioning control for logs
  # checkov:skip=CKV_AWS_145:KMS key encryption is more for long term security
  bucket        = "aigrid-lb-logs-${var.cluster_name}-${data.aws_caller_identity.current.account_id}"
  force_destroy = true

  tags = {
    Name = "aigrid-lb-logs-${var.cluster_name}"
  }
}

resource "aws_s3_bucket_public_access_block" "lb_logs" {
  bucket = aws_s3_bucket.lb_logs.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "lb_logs" {
  bucket = aws_s3_bucket.lb_logs.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "lb_logs" {
  bucket = aws_s3_bucket.lb_logs.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "lb_logs" {
  bucket = aws_s3_bucket.lb_logs.id

  rule {
    id     = "expire-old-logs"
    status = "Enabled"
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }

    expiration {
      days = 90
    }
  }
}

resource "aws_s3_bucket_policy" "lb_logs" {
  bucket = aws_s3_bucket.lb_logs.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowELBPutObject"
        Effect = "Allow"
        Principal = {
          Service = "delivery.logs.amazonaws.com"
        }
        Action   = "s3:PutObject"
        Resource = "${aws_s3_bucket.lb_logs.arn}/*"
        Condition = {
          StringEquals = {
            "aws:SourceAccount" = data.aws_caller_identity.current.account_id
          }
        }
      },
      {
        Sid    = "AllowELBGetAcl"
        Effect = "Allow"
        Principal = {
          Service = "delivery.logs.amazonaws.com"
        }
        Action   = "s3:GetBucketAcl"
        Resource = aws_s3_bucket.lb_logs.arn
        Condition = {
          StringEquals = {
            "aws:SourceAccount" = data.aws_caller_identity.current.account_id
          }
        }
      }
    ]
  })

  depends_on = [aws_s3_bucket_public_access_block.lb_logs]
}
