# ─── SA token signing key ─────────────────────────────────────────────────────
# Managed here so the public key can be published as JWKS for IRSA.
# Injected into the Talos apiserver config in talos.tf.

resource "tls_private_key" "sa_signing" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

# ─── OIDC discovery bucket ────────────────────────────────────────────────────
# checkov:skip=CKV_AWS_144:cross-region replication not required
# checkov:skip=CKV2_AWS_61:lifecycle rules defined in aws_s3_bucket_lifecycle_configuration
# checkov:skip=CKV2_AWS_62:event notifications not needed
# checkov:skip=CKV_AWS_18:no access logging needed for OIDC discovery bucket
# checkov:skip=CKV_AWS_21:versioning not required for static content
# checkov:skip=CKV_AWS_145:KMS not required; objects are intentionally public

resource "aws_s3_bucket" "oidc" {
  # checkov:skip=CKV_AWS_144:cross-region replication not required
  # checkov:skip=CKV2_AWS_61:lifecycle rules defined in aws_s3_bucket_lifecycle_configuration
  # checkov:skip=CKV2_AWS_62:event notifications not needed
  # checkov:skip=CKV_AWS_18:no access logging needed for OIDC discovery bucket
  # checkov:skip=CKV_AWS_21:versioning not required for static content
  # checkov:skip=CKV_AWS_145:KMS not required; objects are intentionally public
  # checkov:skip=CKV2_AWS_6:public access block defined in aws_s3_bucket_public_access_block.oidc line 36
  bucket = "aigrid-oidc-${var.cluster_name}-${data.aws_caller_identity.current.account_id}"

  tags = {
    Name = "aigrid-oidc-${var.cluster_name}"
  }


}

# Objects are intentionally world-readable — AWS STS must fetch the JWKS.
resource "aws_s3_bucket_public_access_block" "oidc" {
  # checkov:skip=CKV_AWS_53:public access intentionally allowed for OIDC discovery
  # checkov:skip=CKV_AWS_54:public access intentionally allowed for OIDC discovery
  # checkov:skip=CKV_AWS_55:public access intentionally allowed for OIDC discovery
  # checkov:skip=CKV_AWS_56:public access intentionally allowed for OIDC discovery
  bucket = aws_s3_bucket.oidc.id

  block_public_acls       = false
  block_public_policy     = false
  ignore_public_acls      = false
  restrict_public_buckets = false
}

resource "aws_s3_bucket_policy" "oidc" {
  # checkov:skip=CKV_AWS_70: * Principal required for public key discovery
  bucket = aws_s3_bucket.oidc.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AllowPublicRead"
      Effect    = "Allow"
      Principal = "*"
      Action    = "s3:GetObject"
      Resource  = "${aws_s3_bucket.oidc.arn}/*"
    }]
  })



  depends_on = [aws_s3_bucket_public_access_block.oidc]
}


resource "aws_s3_bucket_lifecycle_configuration" "incomplete_uploads" {
  bucket = aws_s3_bucket.oidc.id

  rule {
    id     = "expire-old-uploads"
    status = "Enabled"
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }

    expiration {
      days = 90
    }
  }
}



locals {
  oidc_issuer_url   = "https://${aws_s3_bucket.oidc.bucket_regional_domain_name}"
  oidc_provider_url = aws_s3_bucket.oidc.bucket_regional_domain_name
}

# ─── OIDC discovery document ──────────────────────────────────────────────────

resource "aws_s3_object" "oidc_discovery" {
  bucket       = aws_s3_bucket.oidc.id
  key          = ".well-known/openid-configuration"
  content_type = "application/json"

  content = jsonencode({
    issuer                                = local.oidc_issuer_url
    jwks_uri                              = "${local.oidc_issuer_url}/openid/v1/jwks"
    response_types_supported              = ["id_token"]
    subject_types_supported               = ["public"]
    id_token_signing_alg_values_supported = ["RS256"]
  })

  depends_on = [aws_s3_bucket_public_access_block.oidc]
}

# ─── JWKS ─────────────────────────────────────────────────────────────────────
# data.external is deferred to apply time when public_key_pem is unknown at plan.

data "external" "jwks" {
  program = ["python3", "${path.module}/scripts/pem_to_jwks.py"]
  query = {
    public_key_pem = tls_private_key.sa_signing.public_key_pem
  }
}

resource "aws_s3_object" "oidc_jwks" {
  bucket       = aws_s3_bucket.oidc.id
  key          = "openid/v1/jwks"
  content_type = "application/json"
  content      = data.external.jwks.result.jwks

  depends_on = [aws_s3_bucket_public_access_block.oidc]
}

# ─── IAM OIDC provider ────────────────────────────────────────────────────────
# Thumbprint is fetched from the S3 TLS endpoint after objects are uploaded.

data "tls_certificate" "oidc" {
  url        = "${local.oidc_issuer_url}/.well-known/openid-configuration"
  depends_on = [aws_s3_object.oidc_discovery]
}

resource "aws_iam_openid_connect_provider" "this" {
  url             = local.oidc_issuer_url
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.oidc.certificates[0].sha1_fingerprint]
}
