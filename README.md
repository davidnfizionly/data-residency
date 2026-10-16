# Data Residency Proof Platform on AWS

Verifiable EU/US data residency for a multi-tenant SaaS data plane, proven by Git history, runtime traces and account-level guardrails.

## Architecture Decisions

**Gated auto-apply over approving every plan by hand.** A script reads the saved Terraform plan as JSON and applies it without a manual approval only if nothing is deleted, no account, organization or SCP is touched, and no IAM permission uses a generic action or resource that is not documented in `docs/DECISIONS.md`. Any other plan waits for a manual approval. The rule is in ADR-005.
