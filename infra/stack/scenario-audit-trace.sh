#!/usr/bin/env bash
# Scenario 1 - audit trace walkthrough for one tenant.
# Writes one synthetic record through the API, reads its trace back, checks storage_region against
# tenant_region, ties the deployed commit to the Git commit that last changed the routing, and
# confirms the item and its access-log object exist in the tenant's region only.
# Usage: ./scenario-audit-trace.sh [tenant_id]   (run from infra/stack, management account credentials)
set -uo pipefail
TENANT=${1:-synthetic-eu-01}
redact() { sed -E 's/(^|[^0-9a-zA-Z])[0-9]{12}([^0-9a-zA-Z]|$)/\1<account-id>\2/g; s/data-residency-logs-(eu|us)-[a-z0-9]+/data-residency-logs-\1-<suffix>/g'; }
API=$(terraform output -raw api_endpoint)
eval "$(aws configure export-credentials --format env)"
sig=(--aws-sigv4 "aws:amz:eu-west-1:execute-api" --user "$AWS_ACCESS_KEY_ID:$AWS_SECRET_ACCESS_KEY")
[ -n "${AWS_SESSION_TOKEN:-}" ] && sig+=(-H "x-amz-security-token: $AWS_SESSION_TOKEN")

{
echo "=== 1. Write one synthetic record for $TENANT"
w=$(curl -s "${sig[@]}" -X POST "${API}records" -H 'content-type: application/json' -d "{\"tenant_id\":\"$TENANT\",\"payload\":{\"note\":\"audit walkthrough\"}}")
echo "$w" | jq .
TRACE=$(jq -r .trace_id <<<"$w"); RECORD=$(jq -r .record_id <<<"$w")

echo "=== 2. Read the trace back (GET /traces)"
for i in $(seq 1 12); do
  t=$(curl -s "${sig[@]}" "${API}traces?tenant_id=$TENANT" | jq --arg t "$TRACE" '.traces[] | select(.trace_id == $t)')
  [ -n "$t" ] && break; sleep 2.5
done
jq '{trace_id, root: (.root | {tenant_id, tenant_region, data_classification, storage_region, "residency.compliant", outcome, "deployment.git_commit", "routing.registry_sha256"}), spans: [.spans[] | {name, status, storage_region: .attributes.storage_region, duration_ms}]}' <<<"$t"
TR=$(jq -r .root.tenant_region <<<"$t"); SR=$(jq -r .root.storage_region <<<"$t"); COMMIT=$(jq -r '.root["deployment.git_commit"]' <<<"$t")
echo "Check: tenant_region=$TR storage_region=$SR -> $([ "$TR" = "$SR" ] && echo MATCH || echo MISMATCH)"

echo "=== 3. Git: the deployed commit and the commit that defined this routing"
ROOT=$(git rev-parse --show-toplevel)
git fetch -q origin main
echo "Deployed commit (span deployment.git_commit): $(git log -1 --format='%h %cI %s' "$COMMIT")"
echo "Last change to infra/stack/tenants.json at that commit: $(git -C "$ROOT" log -1 --format='%h %cI %s' "$COMMIT" -- infra/stack/tenants.json)"
echo "Registry entry at the deployed commit:"
git show "$COMMIT:infra/stack/tenants.json" | jq -c --arg t "$TENANT" '{($t): .[$t]}'

echo "=== 4. Physical check in each member account"
for zone in eu us; do
  account=$(terraform -chdir=../org output -json member_account_ids | jq -r ".$zone")
  creds=$(aws sts assume-role --role-arn "arn:aws:iam::$account:role/OrganizationAccountAccessRole" --role-session-name audit-check --query Credentials --output json)
  export AWS_ACCESS_KEY_ID=$(jq -r .AccessKeyId <<<"$creds") AWS_SECRET_ACCESS_KEY=$(jq -r .SecretAccessKey <<<"$creds") AWS_SESSION_TOKEN=$(jq -r .SessionToken <<<"$creds")
  region=$([ "$zone" = eu ] && echo eu-west-1 || echo us-east-1)
  item=$(aws dynamodb get-item --region "$region" --table-name "data-residency-pii-$zone" \
    --key "{\"tenant_id\":{\"S\":\"$TENANT\"},\"record_id\":{\"S\":\"$RECORD\"}}" --query 'Item.trace_id.S' --output text)
  bucket=$(aws s3api list-buckets --query "Buckets[?starts_with(Name,'data-residency-logs-$zone-')].Name" --output text)
  log=$(aws s3api list-objects-v2 --bucket "$bucket" --prefix "access/$(date -u +%F)/$RECORD.json" --query 'length(Contents || `[]`)' --output text)
  echo "$zone account, data-residency-pii-$zone ($region): item for record $RECORD -> ${item/None/not present}; access-log objects for it -> $log"
  unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
done
} 2>&1 | redact
