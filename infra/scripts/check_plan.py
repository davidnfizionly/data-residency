#!/usr/bin/env python3
"""Auto-apply gate: checks a Terraform plan JSON (terraform show -json) against three rules.

(a) nothing is deleted or replaced
(b) no account, organization or SCP resource is created, changed or deleted
(c) no IAM permission uses a generic action or resource, unless the resource address is
    listed in docs/DECISIONS.md as `wildcard-exception: <address>`

Exit 0 when every rule passes, 1 otherwise. Unknown policy values fail closed.
"""
import json
import re
import sys
from pathlib import Path

ORG_PREFIXES = ("aws_organizations_", "aws_account_")
POLICY_TYPES = {
    "aws_iam_policy": ["policy"],
    "aws_iam_role_policy": ["policy"],
    "aws_iam_user_policy": ["policy"],
    "aws_iam_group_policy": ["policy"],
    "aws_iam_role": ["assume_role_policy"],
}
ATTACHMENT_TYPES = {
    "aws_iam_role_policy_attachment",
    "aws_iam_user_policy_attachment",
    "aws_iam_group_policy_attachment",
    "aws_iam_policy_attachment",
}


def documented_exceptions():
    path = Path(__file__).resolve().parents[2] / "docs" / "DECISIONS.md"
    if not path.exists():
        return set()
    return set(re.findall(r"wildcard-exception: ([\w.\[\]\"-]+)", path.read_text()))


def as_list(value):
    return value if isinstance(value, list) else [value]


def generic_resource(res):
    if res == "*":
        return True
    parts = res.split(":", 5)
    # arn:partition:service:region:account:resource - a bare "*" in service or resource part
    return len(parts) == 6 and ("*" in parts[2] or parts[5] in ("*", "/*"))


def policy_problems(doc, field):
    problems = []
    for stmt in as_list(doc.get("Statement", [])):
        if stmt.get("Effect") != "Allow":
            continue
        if "NotAction" in stmt or "NotResource" in stmt:
            problems.append(f"{field}: Allow with NotAction/NotResource")
        if field == "assume_role_policy":
            principal = stmt.get("Principal")
            if principal == "*" or (isinstance(principal, dict) and "*" in as_list(principal.get("AWS", []))):
                problems.append(f"{field}: Principal *")
            continue
        for action in as_list(stmt.get("Action", [])):
            if "*" in action:
                problems.append(f"{field}: generic action {action}")
        for res in as_list(stmt.get("Resource", [])):
            if generic_resource(res):
                problems.append(f"{field}: generic resource {res}")
    return problems


def check(plan):
    exceptions = documented_exceptions()
    failures = []
    for rc in plan.get("resource_changes", []):
        actions = rc["change"]["actions"]
        if actions in (["no-op"], ["read"]):
            continue
        addr, rtype = rc["address"], rc["type"]
        after = rc["change"].get("after") or {}
        unknown = rc["change"].get("after_unknown") or {}

        if "delete" in actions:
            failures.append(f"(a) {addr}: {'/'.join(actions)}")
        if rtype.startswith(ORG_PREFIXES):
            failures.append(f"(b) {addr}: {rtype} {'/'.join(actions)}")

        iam_problems = []
        for field in POLICY_TYPES.get(rtype, []):
            if unknown.get(field):
                iam_problems.append(f"{field} unknown at plan time")
            elif after.get(field):
                iam_problems += policy_problems(json.loads(after[field]), field)
        if rtype == "aws_iam_role":
            for i, inline in enumerate(after.get("inline_policy") or []):
                if inline.get("policy"):
                    iam_problems += policy_problems(json.loads(inline["policy"]), f"inline_policy[{i}]")
        if rtype in ATTACHMENT_TYPES:
            arn = after.get("policy_arn")
            if not arn:
                iam_problems.append("policy_arn unknown at plan time")
            elif ":iam::aws:policy/" in arn:
                iam_problems.append(f"AWS managed policy {arn.split('/')[-1]}")
        if iam_problems and addr not in exceptions:
            failures += [f"(c) {addr}: {p}" for p in iam_problems]
    return failures


def main():
    if len(sys.argv) != 2:
        sys.exit("usage: check_plan.py <plan.json>")
    plan = json.loads(Path(sys.argv[1]).read_text())
    failures = check(plan)
    if failures:
        print("AUTO-APPLY REFUSED:")
        for f in failures:
            print(f"  {f}")
        sys.exit(1)
    print("AUTO-APPLY ALLOWED: no delete, no account/organization/SCP change, no undocumented IAM wildcard")


if __name__ == "__main__":
    main()
