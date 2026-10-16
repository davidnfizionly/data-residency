#!/usr/bin/env bash
# Plans a stack, prints the plan summary, and applies the saved plan only if check_plan.py passes.
# Usage: infra/scripts/safe-apply.sh <stack-dir> [extra terraform plan args]
set -euo pipefail

STACK="$1"; shift
SCRIPTS="$(cd "$(dirname "$0")" && pwd)"
PLAN="auto.tfplan"

terraform -chdir="$STACK" plan -input=false -no-color -out="$PLAN" "$@" > /dev/null
terraform -chdir="$STACK" show -json "$PLAN" > "$STACK/$PLAN.json"

echo "Plan summary for $STACK:"
terraform -chdir="$STACK" show -no-color "$PLAN" | grep -E '^  # .* (will|must) be|^Plan:|^No changes' || true

if [ "$(jq '[.resource_changes[]? | select(.change.actions != ["no-op"] and .change.actions != ["read"])] | length' "$STACK/$PLAN.json")" = "0" ]; then
  echo "No changes, nothing to apply."
  rm -f "$STACK/$PLAN" "$STACK/$PLAN.json"
  exit 0
fi

if python3 "$SCRIPTS/check_plan.py" "$STACK/$PLAN.json"; then
  terraform -chdir="$STACK" apply -input=false -no-color "$PLAN"
  rm -f "$STACK/$PLAN" "$STACK/$PLAN.json"
else
  echo "Saved plan left at $STACK/$PLAN for manual review."
  exit 1
fi
