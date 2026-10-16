#!/usr/bin/env bash
# Evaluates the residency policy against a Terraform plan JSON.
# Prints each violation in plain language and exits 1 if there is any.
# Usage: policy/check-plan.sh <plan.json>
set -euo pipefail

POLICY="$(cd "$(dirname "$0")" && pwd)/residency.rego"
violations=$(opa eval --data "$POLICY" --input "$1" --format raw 'concat("\n", sort(data.terraform.residency.deny))')

if [ -n "$violations" ]; then
  echo "OPA residency check FAILED:"
  echo "$violations"
  exit 1
fi
echo "OPA residency check passed: no tenant, table or replica leaves its region."
