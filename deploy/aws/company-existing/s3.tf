# =============================================================================
# S3 — LiteLLM Proxy Config
# =============================================================================
# Stores the active proxy config.yaml in S3.
# The ECS entrypoint downloads this at container start.
# =============================================================================

resource "aws_s3_bucket" "config" {
  bucket        = "${local.name_prefix}-config-${data.aws_caller_identity.current.account_id}"
  force_destroy = var.s3_force_destroy
  tags          = local.common_tags

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_versioning" "config" {
  bucket = aws_s3_bucket.config.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "config" {
  bucket = aws_s3_bucket.config.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "config" {
  bucket = aws_s3_bucket.config.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Config file upload — triggers when local config.yaml changes
resource "aws_s3_object" "config" {
  bucket = aws_s3_bucket.config.id
  key    = "config.yaml"
  source = var.proxy_config_source != "" ? var.proxy_config_source : null
  etag   = var.proxy_config_source != "" ? filemd5(var.proxy_config_source) : null
}
