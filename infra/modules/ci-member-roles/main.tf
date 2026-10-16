# CI roles in a member account: a read-only plan role and a deploy role, each assumable
# only by the matching CI role in the management account. Neither can read PII items or log objects.

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

variable "account_id" {
  type = string
}

variable "home_region" {
  type = string
}

variable "mgmt_plan_role_arn" {
  type = string
}

variable "mgmt_apply_role_arn" {
  type = string
}

locals {
  table_arn  = "arn:aws:dynamodb:${var.home_region}:${var.account_id}:table/data-residency-pii-${var.zone}"
  bucket_arn = "arn:aws:s3:::data-residency-logs-${var.zone}-*"
  writer_arn = "arn:aws:iam::${var.account_id}:role/data-residency-writer-${var.zone}"

  read_statements = [
    {
      Sid      = "ReadTableConfig"
      Effect   = "Allow"
      Action   = ["dynamodb:Describe*", "dynamodb:ListTagsOfResource"]
      Resource = local.table_arn
    },
    {
      Sid      = "ReadBucketConfig"
      Effect   = "Allow"
      Action   = ["s3:GetBucket*", "s3:GetEncryptionConfiguration", "s3:GetLifecycleConfiguration", "s3:GetReplicationConfiguration", "s3:GetAccelerateConfiguration", "s3:ListBucket"]
      Resource = local.bucket_arn
    },
    {
      Sid      = "ReadWriterRole"
      Effect   = "Allow"
      Action   = ["iam:GetRole", "iam:GetRolePolicy", "iam:ListRolePolicies", "iam:ListAttachedRolePolicies"]
      Resource = local.writer_arn
    },
  ]
}

resource "aws_iam_role" "plan" {
  name = "data-residency-ci-plan"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Principal = { AWS = var.mgmt_plan_role_arn }, Action = "sts:AssumeRole" }]
  })
}

resource "aws_iam_role_policy" "plan" {
  name   = "read-data-plane-config"
  role   = aws_iam_role.plan.id
  policy = jsonencode({ Version = "2012-10-17", Statement = local.read_statements })
}

resource "aws_iam_role" "deploy" {
  name = "data-residency-ci-deploy"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Principal = { AWS = var.mgmt_apply_role_arn }, Action = "sts:AssumeRole" }]
  })
}

resource "aws_iam_role_policy" "deploy" {
  name = "deploy-data-plane"
  role = aws_iam_role.deploy.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(local.read_statements, [
      {
        Sid      = "ManageTable"
        Effect   = "Allow"
        Action   = ["dynamodb:CreateTable", "dynamodb:UpdateTable", "dynamodb:DeleteTable", "dynamodb:UpdateContinuousBackups", "dynamodb:UpdateTimeToLive", "dynamodb:TagResource", "dynamodb:UntagResource"]
        Resource = local.table_arn
      },
      {
        Sid      = "ManageBucket"
        Effect   = "Allow"
        Action   = ["s3:CreateBucket", "s3:DeleteBucket", "s3:PutBucketPolicy", "s3:DeleteBucketPolicy", "s3:PutEncryptionConfiguration", "s3:PutBucketPublicAccessBlock", "s3:PutBucketOwnershipControls", "s3:PutBucketTagging"]
        Resource = local.bucket_arn
      },
      {
        Sid      = "ManageWriterRole"
        Effect   = "Allow"
        Action   = ["iam:CreateRole", "iam:DeleteRole", "iam:UpdateRole", "iam:UpdateAssumeRolePolicy", "iam:PutRolePolicy", "iam:DeleteRolePolicy", "iam:TagRole", "iam:UntagRole", "iam:ListInstanceProfilesForRole"]
        Resource = local.writer_arn
      },
    ])
  })
}
