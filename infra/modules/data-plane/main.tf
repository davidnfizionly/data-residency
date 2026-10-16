# Regional data plane: one PII table and one access-log bucket, both in the provider's region.
# The same module is applied once per member account (EU in eu-west-1, US in us-east-1).

terraform {
  required_providers {
    aws = {
      source = "hashicorp/aws"
    }
  }
}

variable "zone" {
  description = "Residency zone of this data plane (eu or us)"
  type        = string
}

data "aws_region" "current" {}

locals {
  tags = {
    ResidencyZone = var.zone
    HomeRegion    = data.aws_region.current.region
  }
}

resource "aws_dynamodb_table" "pii" {
  name         = "data-residency-pii-${var.zone}"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "tenant_id"
  range_key    = "record_id"

  attribute {
    name = "tenant_id"
    type = "S"
  }

  attribute {
    name = "record_id"
    type = "S"
  }

  tags = merge(local.tags, { DataClassification = "pii" })
}

resource "aws_s3_bucket" "logs" {
  bucket_prefix = "data-residency-logs-${var.zone}-"

  # Logs hold synthetic identifiers only, so the bucket can be emptied on destroy.
  force_destroy = true

  tags = merge(local.tags, { DataClassification = "access-log" })
}

resource "aws_s3_bucket_server_side_encryption_configuration" "logs" {
  bucket = aws_s3_bucket.logs.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "logs" {
  bucket = aws_s3_bucket.logs.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "logs" {
  bucket = aws_s3_bucket.logs.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

data "aws_iam_policy_document" "logs_tls_only" {
  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.logs.arn, "${aws_s3_bucket.logs.arn}/*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "logs" {
  bucket = aws_s3_bucket.logs.id
  policy = data.aws_iam_policy_document.logs_tls_only.json

  depends_on = [aws_s3_bucket_public_access_block.logs]
}

output "table_name" {
  value = aws_dynamodb_table.pii.name
}

output "table_arn" {
  value = aws_dynamodb_table.pii.arn
}

output "log_bucket" {
  value = aws_s3_bucket.logs.id
}

output "region" {
  value = data.aws_region.current.region
}
