#!/usr/bin/env bash
# Harmless SCP deny tests: every call targets a table that does not exist.
# A denied call returns AccessDeniedException (SCP); an allowed call returns ResourceNotFoundException.
# Run from infra/org with management account credentials. Account and policy IDs are redacted.
set -uo pipefail

redact() { sed -E 's/[0-9]{12}/<account-id>/g; s/(o|p|r)-[a-z0-9]{8,32}/\1-<id>/g; s/[A-Z0-9]{20}:[a-zA-Z0-9-]+/<session>/g'; }

put() { # zone region table
  aws dynamodb put-item --region "$2" --table-name "$3" \
    --item '{"tenant_id":{"S":"synthetic-tenant-001"}}' 2>&1 | redact
}

for zone in eu us; do
  account=$(terraform output -json member_account_ids | jq -r ".$zone")
  creds=$(aws sts assume-role --role-arn "arn:aws:iam::$account:role/OrganizationAccountAccessRole" \
    --role-session-name scp-test --query Credentials --output json)
  export AWS_ACCESS_KEY_ID=$(jq -r .AccessKeyId <<<"$creds")
  export AWS_SECRET_ACCESS_KEY=$(jq -r .SecretAccessKey <<<"$creds")
  export AWS_SESSION_TOKEN=$(jq -r .SessionToken <<<"$creds")
  if [ "$zone" = eu ]; then home=eu-west-1; other=us-east-1; else home=us-east-1; other=eu-west-1; fi

  echo "=== $zone account (home region $home), role session without tenant_region tag"
  echo "--- 1. Non-PII table write in the OTHER region ($other): expect SCP deny (region lock)"
  put "$zone" "$other" data-residency-gate-test
  echo "--- 2. PII table write in the HOME region ($home), no tenant_region tag: expect SCP deny (tenant check)"
  put "$zone" "$home" "data-residency-pii-$zone"
  echo "--- 3. Control: non-PII table write in the HOME region ($home): expect ResourceNotFoundException (SCP allows)"
  put "$zone" "$home" data-residency-gate-test
  unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
done
