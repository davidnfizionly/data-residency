#!/usr/bin/env bash
# Shows where each data plane resource physically lives, per member account and region,
# and checks that the SCP denies S3 replication on the real log bucket.
# Run from infra/stack with management account credentials. IDs and bucket suffixes are redacted.
set -uo pipefail

redact() { sed -E 's/[0-9]{12}/<account-id>/g; s/(o|p)-[a-z0-9]{8,32}/\1-<id>/g; s/data-residency-logs-(eu|us)-[a-z0-9]+/data-residency-logs-\1-<suffix>/g'; }

for zone in eu us; do
  account=$(jq -r ".$zone" <<<"$(terraform -chdir=../org output -json member_account_ids)")
  creds=$(aws sts assume-role --role-arn "arn:aws:iam::$account:role/OrganizationAccountAccessRole" \
    --role-session-name placement-check --query Credentials --output json)
  export AWS_ACCESS_KEY_ID=$(jq -r .AccessKeyId <<<"$creds")
  export AWS_SECRET_ACCESS_KEY=$(jq -r .SecretAccessKey <<<"$creds")
  export AWS_SESSION_TOKEN=$(jq -r .SessionToken <<<"$creds")

  echo "=== $zone account"
  for region in eu-west-1 us-east-1; do
    tables=$(aws dynamodb list-tables --region "$region" --query 'TableNames' --output text)
    echo "DynamoDB tables in $region: ${tables:-none}"
  done
  for bucket in $(aws s3api list-buckets --query 'Buckets[?starts_with(Name, `data-residency-logs-`)].Name' --output text); do
    loc=$(aws s3api get-bucket-location --bucket "$bucket" --query LocationConstraint --output text)
    [ "$loc" = "None" ] && loc=us-east-1
    echo "S3 bucket $bucket: $loc"
  done
  table="data-residency-pii-$zone"
  home=$([ "$zone" = eu ] && echo eu-west-1 || echo us-east-1)
  echo "Table tags: $(aws dynamodb list-tags-of-resource --region "$home" \
    --resource-arn "arn:aws:dynamodb:$home:$account:table/$table" \
    --query 'Tags[].[Key,Value]' --output text | tr '\t\n' '= ' )"
  echo "--- S3 replication on the real log bucket: expect SCP deny"
  aws s3api put-bucket-replication --bucket "$bucket" --replication-configuration \
    "{\"Role\":\"arn:aws:iam::$account:role/none\",\"Rules\":[{\"Status\":\"Enabled\",\"Priority\":1,\"Filter\":{},\"DeleteMarkerReplication\":{\"Status\":\"Disabled\"},\"Destination\":{\"Bucket\":\"arn:aws:s3:::none\"}}]}" 2>&1
  unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
done 2>&1 | redact
