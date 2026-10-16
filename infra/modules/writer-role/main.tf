# Writer role in a member account, assumed by the router with a tenant_region session tag.
# It can only write items to this data plane's PII table and access-log objects to its bucket.
# No data sources here, so the stack can order it after the router role with depends_on.

terraform {
  required_providers {
    aws = {
      source = "hashicorp/aws"
    }
  }
}

variable "zone" {
  type = string
}

variable "router_role_arn" {
  type = string
}

variable "table_arn" {
  type = string
}

variable "log_bucket" {
  type = string
}

resource "aws_iam_role" "writer" {
  name = "data-residency-writer-${var.zone}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { AWS = var.router_role_arn }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
      Condition = {
        "ForAllValues:StringEquals" = { "aws:TagKeys" = ["tenant_region"] }
      }
    }]
  })

  tags = { ResidencyZone = var.zone }
}

resource "aws_iam_role_policy" "writer" {
  name = "write-own-data-plane"
  role = aws_iam_role.writer.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "PutPiiItems"
        Effect   = "Allow"
        Action   = ["dynamodb:PutItem"]
        Resource = var.table_arn
      },
      {
        Sid      = "PutAccessLogs"
        Effect   = "Allow"
        Action   = ["s3:PutObject"]
        Resource = "arn:aws:s3:::${var.log_bucket}/access/*"
      },
    ]
  })
}

output "role_arn" {
  value = aws_iam_role.writer.arn
}
