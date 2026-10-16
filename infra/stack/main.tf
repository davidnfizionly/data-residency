# Application stack: the EU and US data planes (one per member account and region),
# plus the router and API in the management account.

terraform {
  required_version = ">= 1.10"

  # Bucket, region and locking come from the ignored infra/state.tfbackend file.
  backend "s3" {
    key = "stack/terraform.tfstate"
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.7"
    }
  }
}

variable "member_account_ids" {
  description = "Member account IDs keyed by zone (eu, us). Set in an ignored *.tfvars file or TF_VAR_member_account_ids."
  type        = map(string)
}

variable "member_role_name" {
  description = "Role assumed in each member account: OrganizationAccountAccessRole locally, the CI plan or deploy role in the pipeline"
  type        = string
  default     = "OrganizationAccountAccessRole"
}

locals {
  default_tags = { Project = "data-residency" }
}

# Management account, eu-west-1: router, API, span log group.
provider "aws" {
  region = "eu-west-1"

  default_tags {
    tags = local.default_tags
  }
}

provider "aws" {
  alias  = "eu"
  region = "eu-west-1"

  assume_role {
    role_arn = "arn:aws:iam::${var.member_account_ids["eu"]}:role/${var.member_role_name}"
  }

  default_tags {
    tags = local.default_tags
  }
}

provider "aws" {
  alias  = "us"
  region = "us-east-1"

  assume_role {
    role_arn = "arn:aws:iam::${var.member_account_ids["us"]}:role/${var.member_role_name}"
  }

  default_tags {
    tags = local.default_tags
  }
}

module "data_plane_eu" {
  source    = "../modules/data-plane"
  providers = { aws = aws.eu }
  zone      = "eu"
}

module "data_plane_us" {
  source    = "../modules/data-plane"
  providers = { aws = aws.us }
  zone      = "us"
}

output "data_planes" {
  value = {
    eu = { table = module.data_plane_eu.table_name, region = module.data_plane_eu.region }
    us = { table = module.data_plane_us.table_name, region = module.data_plane_us.region }
  }
}
