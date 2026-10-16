#!/usr/bin/env bash
# CLI tests of the router: signed API calls, an unsigned call, a deliberate misroute
# (direct invocation only), the trace read-back, and where the records physically landed.
# Run from infra/stack with management account credentials. IDs are redacted in the output.
set -uo pipefail

redact() { sed -E 's/(^|[^0-9a-zA-Z])[0-9]{12}([^0-9a-zA-Z]|$)/\1<account-id>\2/g; s/[a-z0-9]{10}\.execute-api/<api-id>.execute-api/g; s/(o|p)-[a-z0-9]{8,32}/\1-<id>/g'; }
API=$(terraform output -raw api_endpoint)
eval "$(aws configure export-credentials --format env)"
sig=(--aws-sigv4 "aws:amz:eu-west-1:execute-api" --user "$AWS_ACCESS_KEY_ID:$AWS_SECRET_ACCESS_KEY")
[ -n "${AWS_SESSION_TOKEN:-}" ] && sig+=(-H "x-amz-security-token: $AWS_SESSION_TOKEN")
call() { curl -s "${sig[@]}" -w '\nHTTP %{http_code}, %{time_total}s\n' "$@"; }

{
echo "=== 1. GET /tenants (signed)"
call "${API}tenants" | sed '1s/.*/&/' 

for t in synthetic-eu-01 synthetic-us-01; do
  echo "=== 2. POST /records for $t (signed)"
  call -X POST "${API}records" -H 'content-type: application/json' \
    -d "{\"tenant_id\":\"$t\",\"payload\":{\"note\":\"synthetic record\"}}"
done

echo "=== 3. POST /records without a signature: expect 403 from API Gateway IAM auth"
curl -s -w '\nHTTP %{http_code}\n' -X POST "${API}records" -d '{"tenant_id":"synthetic-eu-01"}'

echo "=== 4. Deliberate mismatch: EU tenant forced to us-east-1 by direct invocation: expect SCP deny"
aws lambda invoke --region eu-west-1 --function-name data-residency-router --cli-binary-format raw-in-base64-out \
  --payload '{"route":"POST /records","tenant_id":"synthetic-eu-01","payload":{"note":"misroute test"},"simulate_storage_region":"us-east-1"}' \
  /dev/stdout --query StatusCode --output text | jq -c '{statusCode, body: (.body | fromjson)}' 2>/dev/null

sleep 5
echo "=== 5. GET /traces for synthetic-eu-01 (signed): root span residency attributes, newest first"
call "${API}traces?tenant_id=synthetic-eu-01" | head -1 | jq -c '.traces[:3][] | {trace_id, status, tenant_region: .root.tenant_region, data_classification: .root.data_classification, storage_region: .root.storage_region, compliant: .root["residency.compliant"], outcome: .root.outcome, misroute: .root["simulation.misroute"], spans: [.spans[] | "\(.name) \(.status) \(.attributes.storage_region // "-")"]}'

echo "=== 6. Where the records are: tenant_id values stored per account and region"
for zone in eu us; do
  account=$(terraform -chdir=../org output -json member_account_ids | jq -r ".$zone")
  creds=$(aws sts assume-role --role-arn "arn:aws:iam::$account:role/OrganizationAccountAccessRole" --role-session-name read-check --query Credentials --output json)
  for region in eu-west-1 us-east-1; do
    n=$(AWS_ACCESS_KEY_ID=$(jq -r .AccessKeyId <<<"$creds") AWS_SECRET_ACCESS_KEY=$(jq -r .SecretAccessKey <<<"$creds") AWS_SESSION_TOKEN=$(jq -r .SessionToken <<<"$creds") \
      aws dynamodb scan --region "$region" --table-name "data-residency-pii-$zone" --query 'Items[].tenant_id.S' --output text 2>&1 | head -c 300)
    echo "$zone account, data-residency-pii-$zone in $region: $n"
  done
done
} 2>&1 | redact
