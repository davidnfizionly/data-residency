# Architecture Decision Records

One line per decision that is not in `docs/PROJECT_PLAN.md`: what, why, what was rejected.

- **ADR-001 Budget without notifications.** A 5 USD monthly cost budget (credits and refunds excluded) is created only to track spend, with no alert and no e-mail subscriber. Rejected: an e-mail alert, because a cost signal was not wanted in an inbox for this project. Spend is checked by hand in Budgets and Cost Explorer instead.
- **ADR-002 S3 native state locking over a DynamoDB lock table.** Terraform >= 1.10 locks state with a lock file in the state bucket (`use_lockfile`), so one resource fewer is needed. Rejected: the DynamoDB lock table listed in the plan, now deprecated by Terraform for the S3 backend.
- **ADR-003 Backend bootstrap with local state, then migration.** The state bucket stack is applied once with local state and then migrated into the bucket it created. Rejected: creating the bucket by hand with the CLI, which would leave it outside code.
- **ADR-004 Random bucket name and partial backend config.** The state bucket uses `bucket_prefix`, and stacks read the bucket name from an ignored `*.tfbackend` file, so no account ID or bucket name is committed. Rejected: an account-ID-based name in versioned backend blocks.
- **ADR-005 Gated auto-apply.** `infra/scripts/safe-apply.sh` plans a stack, prints the plan summary, and applies the saved plan without a manual approval only when `infra/scripts/check_plan.py` confirms on the plan JSON that (a) nothing is deleted or replaced, (b) no account, organization or SCP resource is created, changed or deleted, and (c) no IAM permission uses a generic action or resource (`*` in an action, `Resource: *`, `NotAction`/`NotResource`, `Principal: *`, AWS managed policy attachments) unless its resource address is listed below as `wildcard-exception: <address>`. Policies unknown at plan time fail closed. Every other plan is approved by hand. Rejected: approving every plan by hand (slow for routine Lambda and data-plane changes) and unconditional auto-apply (no guardrail on the changes that matter for residency).

Documented IAM wildcard exceptions: none.
