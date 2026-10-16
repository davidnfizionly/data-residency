#!/usr/bin/env bash
# Scenario 3 - hard block at the account level. CI is bypassed: the router is invoked directly
# (IAM lambda:InvokeFunction) and forced to write each tenant into the other zone's account.
# Expected: the destination account's SCP denies the write; nothing is stored there.
# Run from infra/stack with management account credentials.
set -uo pipefail
tmp=$(mktemp)
redact() { sed -E 's/(^|[^0-9a-zA-Z])[0-9]{12}([^0-9a-zA-Z]|$)/\1<account-id>\2/g; s/\b(o|r|p)-[a-z0-9]{4,32}\b/\1-<id>/g'; }
{
for pair in "synthetic-eu-01 us-east-1" "synthetic-us-01 eu-west-1"; do
  set -- $pair
  echo "=== Direct invocation: $1 forced to $2"
  aws lambda invoke --region eu-west-1 --function-name data-residency-router --cli-binary-format raw-in-base64-out \
    --payload "{\"route\":\"POST /records\",\"tenant_id\":\"$1\",\"payload\":{\"note\":\"bypass attempt\"},\"simulate_storage_region\":\"$2\"}" \
    "$tmp" > /dev/null && jq '{statusCode, body: (.body | fromjson)}' "$tmp"
done
echo "=== Items stored for the wrong tenant in each account (expect 0)"
for zone in eu us; do
  other=$([ "$zone" = eu ] && echo synthetic-us-01 || echo synthetic-eu-01)
  region=$([ "$zone" = eu ] && echo eu-west-1 || echo us-east-1)
  account=$(terraform -chdir=../org output -json member_account_ids | jq -r ".$zone")
  creds=$(aws sts assume-role --role-arn "arn:aws:iam::$account:role/OrganizationAccountAccessRole" --role-session-name scp-check --query Credentials --output json)
  n=$(AWS_ACCESS_KEY_ID=$(jq -r .AccessKeyId <<<"$creds") AWS_SECRET_ACCESS_KEY=$(jq -r .SecretAccessKey <<<"$creds") AWS_SESSION_TOKEN=$(jq -r .SessionToken <<<"$creds") \
    aws dynamodb query --region "$region" --table-name "data-residency-pii-$zone" --key-condition-expression 'tenant_id = :t' \
    --expression-attribute-values "{\":t\":{\"S\":\"$other\"}}" --select COUNT --query Count --output text)
  echo "data-residency-pii-$zone ($region): items for $other = $n"
done
} 2>&1 | redact
