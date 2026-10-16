# CI identity: GitHub OIDC provider and two roles in the management account.
# - plan role: assumable only from pull_request runs, read-only, plans with -lock=false
# - apply role: assumable only from runs on the main branch (merge and scheduled drift check)
# This stack is applied by hand, never by the pipeline, so CI cannot widen its own permissions.

terraform {
  required_version = ">= 1.10"

  # Bucket, region and locking come from the ignored infra/state.tfbackend file.
  backend "s3" {
    key = "ci/terraform.tfstate"
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

# GitHub issues an immutable OIDC subject for this repository: owner and repository names
# followed by their numeric IDs (see GET /repos/{repo}/actions/oidc/customization/sub).
variable "github_subject_prefix" {
  type    = string
  default = "repo:davidnfizionly@210562805/data-residency@1422220770"
}

variable "state_bucket" {
  description = "Terraform state bucket name (same value as in infra/state.tfbackend)"
  type        = string
}

variable "member_account_ids" {
  type = map(string)
}

locals {
  default_tags = { Project = "data-residency" }
  home_region  = { eu = "eu-west-1", us = "us-east-1" }
}

provider "aws" {
  region = "us-east-1"
  default_tags {
    tags = local.default_tags
  }
}

provider "aws" {
  alias  = "eu"
  region = "eu-west-1"
  assume_role {
    role_arn = "arn:aws:iam::${var.member_account_ids["eu"]}:role/OrganizationAccountAccessRole"
  }
  default_tags {
    tags = local.default_tags
  }
}

provider "aws" {
  alias  = "us"
  region = "us-east-1"
  assume_role {
    role_arn = "arn:aws:iam::${var.member_account_ids["us"]}:role/OrganizationAccountAccessRole"
  }
  default_tags {
    tags = local.default_tags
  }
}

data "aws_caller_identity" "mgmt" {}

locals {
  account      = data.aws_caller_identity.mgmt.account_id
  oidc_arn     = "arn:aws:iam::${local.account}:oidc-provider/token.actions.githubusercontent.com"
  plan_role    = "arn:aws:iam::${local.account}:role/data-residency-ci-plan"
  apply_role   = "arn:aws:iam::${local.account}:role/data-residency-ci-apply"
  router_role  = "arn:aws:iam::${local.account}:role/data-residency-router"
  router_fn    = "arn:aws:lambda:eu-west-1:${local.account}:function:data-residency-router"
  router_logs  = "arn:aws:logs:eu-west-1:${local.account}:log-group:/aws/lambda/data-residency-router"
  state_bucket = "arn:aws:s3:::${var.state_bucket}"

  member_plan_roles   = [for id in values(var.member_account_ids) : "arn:aws:iam::${id}:role/data-residency-ci-plan"]
  member_deploy_roles = [for id in values(var.member_account_ids) : "arn:aws:iam::${id}:role/data-residency-ci-deploy"]

  mgmt_read = [
    {
      Sid       = "ListStackState"
      Effect    = "Allow"
      Action    = ["s3:ListBucket"]
      Resource  = local.state_bucket
      Condition = { StringLike = { "s3:prefix" = ["stack/*"] } }
    },
    {
      Sid      = "ReadStackState"
      Effect   = "Allow"
      Action   = ["s3:GetObject"]
      Resource = "${local.state_bucket}/stack/terraform.tfstate"
    },
    {
      Sid      = "ReadRouterRole"
      Effect   = "Allow"
      Action   = ["iam:GetRole", "iam:GetRolePolicy", "iam:ListRolePolicies", "iam:ListAttachedRolePolicies"]
      Resource = local.router_role
    },
    {
      Sid      = "ReadRouterFunction"
      Effect   = "Allow"
      Action   = ["lambda:Get*", "lambda:List*"]
      Resource = local.router_fn
    },
    {
      Sid      = "ReadHttpApi"
      Effect   = "Allow"
      Action   = ["apigateway:GET"]
      Resource = ["arn:aws:apigateway:eu-west-1::/apis", "arn:aws:apigateway:eu-west-1::/apis/*"]
    },
    {
      Sid      = "ReadLogGroup"
      Effect   = "Allow"
      Action   = ["logs:DescribeLogGroups", "logs:ListTagsForResource"]
      Resource = "arn:aws:logs:eu-west-1:${local.account}:log-group:*"
    },
  ]
}

resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
}

resource "aws_iam_role" "plan" {
  name = "data-residency-ci-plan"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = local.oidc_arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          "token.actions.githubusercontent.com:sub" = "${var.github_subject_prefix}:pull_request"
        }
      }
    }]
  })
  depends_on = [aws_iam_openid_connect_provider.github]
}

resource "aws_iam_role_policy" "plan" {
  name = "plan-stack"
  role = aws_iam_role.plan.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(local.mgmt_read, [{
      Sid      = "AssumeMemberPlanRoles"
      Effect   = "Allow"
      Action   = ["sts:AssumeRole"]
      Resource = local.member_plan_roles
    }])
  })
}

resource "aws_iam_role" "apply" {
  name = "data-residency-ci-apply"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = local.oidc_arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          "token.actions.githubusercontent.com:sub" = "${var.github_subject_prefix}:ref:refs/heads/main"
        }
      }
    }]
  })
  depends_on = [aws_iam_openid_connect_provider.github]
}

resource "aws_iam_role_policy" "apply" {
  name = "apply-stack"
  role = aws_iam_role.apply.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(local.mgmt_read, [
      {
        Sid      = "WriteStackStateAndLock"
        Effect   = "Allow"
        Action   = ["s3:PutObject", "s3:DeleteObject"]
        Resource = ["${local.state_bucket}/stack/terraform.tfstate", "${local.state_bucket}/stack/terraform.tfstate.tflock"]
      },
      {
        Sid      = "ReadStackLock"
        Effect   = "Allow"
        Action   = ["s3:GetObject"]
        Resource = "${local.state_bucket}/stack/terraform.tfstate.tflock"
      },
      {
        Sid      = "ManageRouterRole"
        Effect   = "Allow"
        Action   = ["iam:CreateRole", "iam:DeleteRole", "iam:UpdateRole", "iam:UpdateAssumeRolePolicy", "iam:PutRolePolicy", "iam:DeleteRolePolicy", "iam:TagRole", "iam:UntagRole", "iam:ListInstanceProfilesForRole"]
        Resource = local.router_role
      },
      {
        Sid       = "PassRouterRoleToLambda"
        Effect    = "Allow"
        Action    = ["iam:PassRole"]
        Resource  = local.router_role
        Condition = { StringEquals = { "iam:PassedToService" = "lambda.amazonaws.com" } }
      },
      {
        Sid      = "ManageRouterFunction"
        Effect   = "Allow"
        Action   = ["lambda:CreateFunction", "lambda:UpdateFunctionCode", "lambda:UpdateFunctionConfiguration", "lambda:DeleteFunction", "lambda:AddPermission", "lambda:RemovePermission", "lambda:TagResource", "lambda:UntagResource"]
        Resource = local.router_fn
      },
      {
        Sid      = "ManageHttpApi"
        Effect   = "Allow"
        Action   = ["apigateway:POST", "apigateway:PUT", "apigateway:PATCH", "apigateway:DELETE", "apigateway:TagResource"]
        Resource = ["arn:aws:apigateway:eu-west-1::/apis", "arn:aws:apigateway:eu-west-1::/apis/*", "arn:aws:apigateway:eu-west-1::/tags/*"]
      },
      {
        Sid      = "ManageLogGroup"
        Effect   = "Allow"
        Action   = ["logs:CreateLogGroup", "logs:DeleteLogGroup", "logs:PutRetentionPolicy", "logs:DeleteRetentionPolicy", "logs:TagResource", "logs:UntagResource", "logs:TagLogGroup"]
        Resource = [local.router_logs, "${local.router_logs}:*"]
      },
      {
        Sid      = "AssumeMemberDeployRoles"
        Effect   = "Allow"
        Action   = ["sts:AssumeRole"]
        Resource = local.member_deploy_roles
      },
    ])
  })
}

module "member_eu" {
  source              = "../modules/ci-member-roles"
  providers           = { aws = aws.eu }
  zone                = "eu"
  account_id          = var.member_account_ids["eu"]
  home_region         = local.home_region["eu"]
  mgmt_plan_role_arn  = local.plan_role
  mgmt_apply_role_arn = local.apply_role
  depends_on          = [aws_iam_role.plan, aws_iam_role.apply]
}

module "member_us" {
  source              = "../modules/ci-member-roles"
  providers           = { aws = aws.us }
  zone                = "us"
  account_id          = var.member_account_ids["us"]
  home_region         = local.home_region["us"]
  mgmt_plan_role_arn  = local.plan_role
  mgmt_apply_role_arn = local.apply_role
  depends_on          = [aws_iam_role.plan, aws_iam_role.apply]
}

output "plan_role_arn" {
  value = aws_iam_role.plan.arn
}

output "apply_role_arn" {
  value = aws_iam_role.apply.arn
}
