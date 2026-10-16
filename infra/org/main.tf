# AWS Organizations: the organization, the EU and US member accounts, and one SCP per member account.
# SCPs are attached to the member accounts only, never to the root or the management account.

terraform {
  required_version = ">= 1.10"

  # Bucket, region and locking come from the ignored infra/state.tfbackend file.
  backend "s3" {
    key = "org/terraform.tfstate"
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"

  default_tags {
    tags = {
      Project = "data-residency"
    }
  }
}

variable "member_accounts" {
  description = "Member account e-mails, keyed by residency zone. Set in an ignored *.tfvars file."
  type = map(object({
    email  = string
    region = string
  }))
}

resource "aws_organizations_organization" "this" {
  feature_set          = "ALL"
  enabled_policy_types = ["SERVICE_CONTROL_POLICY"]
}

resource "aws_organizations_account" "member" {
  for_each = var.member_accounts

  name      = "data-residency-${each.key}"
  email     = each.value.email
  role_name = "OrganizationAccountAccessRole"

  # Closing or removing the accounts is decided by hand at cleanup time.
  close_on_deletion = false

  tags = {
    ResidencyZone = each.key
    HomeRegion    = each.value.region
  }

  lifecycle {
    ignore_changes = [role_name]
  }

  depends_on = [aws_organizations_organization.this]
}

resource "aws_organizations_policy" "residency" {
  for_each = var.member_accounts

  name        = "data-residency-${each.key}-guardrail"
  description = "Deny PII and log writes outside ${each.value.region} and PII writes for tenants of another region"
  type        = "SERVICE_CONTROL_POLICY"
  content = templatefile("${path.module}/scp-residency.json.tftpl", {
    home_region = each.value.region
    zone        = each.key
  })
}

resource "aws_organizations_policy_attachment" "residency" {
  for_each = var.member_accounts

  policy_id = aws_organizations_policy.residency[each.key].id
  target_id = aws_organizations_account.member[each.key].id
}

output "member_account_ids" {
  value = { for k, a in aws_organizations_account.member : k => a.id }
}
