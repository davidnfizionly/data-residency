#!/usr/bin/env bash
# Scenario 4 - compliant rollback. Writes one synthetic record for the EU tenant through the API
# every INTERVAL seconds and prints when each write happened and where it went, until STOP_AFTER
# consecutive compliant writes have been seen (or MAX_MINUTES elapse).
# Run from infra/stack with management account credentials.
set -uo pipefail
TENANT=${TENANT:-synthetic-eu-01}; INTERVAL=${INTERVAL:-3}; STOP_AFTER=${STOP_AFTER:-5}; MAX_MINUTES=${MAX_MINUTES:-45}
API=$(terraform output -raw api_endpoint)
end=$(( $(date +%s) + MAX_MINUTES * 60 )); ok=0
while [ "$(date +%s)" -lt "$end" ]; do
  eval "$(aws configure export-credentials --format env)"
  r=$(curl -s --max-time 20 --aws-sigv4 "aws:amz:eu-west-1:execute-api" --user "$AWS_ACCESS_KEY_ID:$AWS_SECRET_ACCESS_KEY" \
    ${AWS_SESSION_TOKEN:+-H "x-amz-security-token: $AWS_SESSION_TOKEN"} -X POST "${API}records" \
    -H 'content-type: application/json' -d "{\"tenant_id\":\"$TENANT\",\"payload\":{\"note\":\"rollback watch\"}}" -w '\n%{http_code}')
  code=$(tail -1 <<<"$r"); body=$(head -n -1 <<<"$r")
  echo "$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ) http=$code $(jq -r '"outcome=\(.outcome) tenant_region=\(.tenant_region) storage_region=\(.storage_region) trace=\(.trace_id)"' <<<"$body" 2>/dev/null)"
  if [ "$code" = 201 ] && [ "$(jq -r .storage_region <<<"$body")" = "$(jq -r .tenant_region <<<"$body")" ]; then ok=$((ok+1)); else ok=0; fi
  [ "$ok" -ge "$STOP_AFTER" ] && break
  sleep "$INTERVAL"
done
