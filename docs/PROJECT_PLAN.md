# Data Residency Proof Platform on AWS - Verifiable Compliance for a Multi-Region SaaS

---

## Project Description

Post-Schrems II, an EU enterprise customer buying a B2B SaaS product can ask a question that has nothing to do with performance or failover: "Prove to me, technically, that my customers' PII never leaves the EEA." This is not a hypothetical - it is a routine procurement and audit requirement, and a Solutions Architect is expected to answer it with evidence, not with a policy document.

This project builds a minimal but real multi-tenant SaaS data plane on AWS, split across two regions (EU and US), where every tenant's data is routed to and physically stored in its assigned region. The point of the project is not the routing itself - that part is simple - it is the **three-layer proof** that the routing is actually honored: a Git-based audit trail for every infrastructure change, a runtime trace that proves where each write actually landed, and an account-level guardrail that blocks a cross-region write even if the application code has a bug. The project explicitly simulates an audit, a violation attempt, and a compliant rollback - each one recorded and demonstrable on camera.

---

## Technologies & Services Used

| Layer | Technology | Purpose |
| --- | --- | --- |
| IaC | **Terraform** | EU and US data-plane stacks, defined once, applied per region |
| Compute | **AWS Lambda** + **Amazon API Gateway** | Regional router - reads the tenant's assigned region and writes only to that region's data plane |
| Data (per region) | **Amazon DynamoDB** (PII table), **Amazon S3** (access logs) | Physically separate storage per region - nothing shared across the EU/US boundary |
| Account boundary | **AWS Organizations** (two accounts: EU, US) + **Service Control Policies (SCPs)** | Hard, infrastructure-level enforcement - denies a cross-region write even if application code or CI is compromised |
| Runtime proof | **OpenTelemetry** | Every request carries a span with `tenant_region`, `data_classification`, and `storage_region`; a mismatch is a detectable violation, not an assumption |
| Policy-as-code | **OPA (Open Policy Agent)** | Evaluates Terraform plans in CI - blocks a pull request that would create a cross-region resource for a PII table, before it ever deploys |
| CI/CD & audit trail | **GitHub Actions** | Enforces PR review, runs `terraform plan`, runs OPA checks, and is the only path allowed to run `terraform apply` on merge |
| Frontend | **React** | Audit console - trace viewer, violation simulator, compliance history |

---

## Architecture Patterns Actually Demonstrated

- **Git history as the audit trail, not a bolted-on logging tool** - every infrastructure change is a reviewed pull request; an auditor opens the repository and sees who changed the routing, when, and why, with no separate audit product required.
- **Policy-as-code as a deploy-time gate** - OPA evaluates the Terraform plan in CI and blocks a violation before it is ever applied, rather than detecting it afterward in production.
- **Defense in depth between CI and infrastructure** - SCPs provide a second, independent enforcement layer at the AWS account level, so a bug in the application or a compromised CI pipeline still cannot physically write EU data into the US account.
- **Runtime evidence, not configuration-only compliance** - OpenTelemetry spans are the actual proof that a specific write landed in the region it was supposed to, closing the gap between "the config says X" and "X actually happened."
- **Idempotent, reviewable rollback** - a compliance violation is corrected with a `git revert`, not a manual console fix, so the fix itself is auditable too.

---

## Demo Scenarios

| Scenario | What Happens | What It Proves |
| --- | --- | --- |
| **Audit trace walkthrough** | An OpenTelemetry trace for an EU tenant's write is pulled up and its `storage_region` is checked against `tenant_region` | Every PII write for that tenant actually landed in `eu-west-1`, correlated against the Git commit that defined the routing |
| **Blocked violation in CI** | A pull request attempts to change the routing so an EU tenant's data would be written to `us-east-1` | OPA fails the CI check and the merge is blocked - the violation never reaches a deployed state |
| **Hard block at the account level** | A simulated bypass of CI (e.g. a direct API call) attempts a cross-region write | The destination account's SCP denies the action outright, independent of whether the application or CI caught it |
| **Compliant rollback** | A merged change is reverted (`git revert` + merge) | Infrastructure returns to the compliant state via `terraform apply`, in under two minutes, with the correction itself traceable in Git |

---

## UI Details

- **Audit console** - lets a non-technical reviewer pick a tenant and see, in plain language, where their data is stored and the trace evidence behind that claim
- **Violation simulator** - triggers the blocked-PR and SCP-denial scenarios live, with the actual error/denial shown as it would appear to an engineer
- **Compliance history timeline** - every infrastructure change affecting PII routing, pulled directly from Git/CI history, displayed as a simple chronological feed
- **Non-technical framing** - a procurement or compliance reviewer can watch a violation get blocked and immediately understand why that matters, without reading Terraform or OPA syntax

---

## Use Case Simulation

| Role | What They'd See/Do in This System |
| --- | --- |
| **Compliance/audit reviewer** | Opens the audit console, picks a tenant, confirms their data never left the assigned region, backed by trace evidence |
| **EU enterprise customer (procurement)** | Is shown the same proof as part of a vendor due-diligence conversation - this is the actual use case driving the project |
| **Platform/Solutions Architect** | Reviews the Git/CI history to confirm every routing change was reviewed and policy-checked before deploy |
| **Developer attempting a change** | Opens a pull request that would violate data residency and is blocked in CI before it can cause harm |

---

## Deployment Strategy

1. **Terraform backend** - S3 state, DynamoDB lock table
2. **Two AWS accounts under AWS Organizations** (EU, US) - minimal setup, scoped to this project's need, not a full landing zone
3. **Service Control Policies** - deny cross-region writes to the PII table at the account level
4. **Regional data planes** - DynamoDB (PII) + S3 (logs) provisioned identically in each region via the same Terraform module
5. **Lambda router + API Gateway** - reads `tenant_region`, writes only to the matching regional data plane
6. **OpenTelemetry instrumentation** - every write carries `tenant_region`, `data_classification`, `storage_region` as span attributes
7. **OPA policies in CI** - Terraform plans are evaluated against a rule that blocks any cross-region PII resource
8. **GitHub Actions pipeline** - PR required, `terraform plan` + OPA check on every PR, `terraform apply` only on merge to main, scheduled drift check via `terraform plan` on a cron
9. **Audit console** - React, Vite, Tailwind, local
10. **Demo scenario validation** - all 4 scenarios run and recorded live
11. **Documentation & proof capture** - screenshots, trace examples, architecture diagram, the Git/CI history itself as evidence
12. **Clean-up** - both regional stacks torn down, second AWS account's billable resources verified against Cost Explorer

---

## What This Actually Demonstrates to a Hiring Manager

- A problem framed the way a senior Solutions Architect actually frames it: "prove it to an auditor," not "deploy to two regions"
- Policy-as-code and account-level guardrails used together, deliberately, as defense in depth - not as a single checkbox
- Direct relevance to a real, current compliance pressure (Schrems II, EU data residency) that enterprise SaaS vendors are actively hiring to solve
- Git/CI used as a compliance instrument, which is a materially different skill than using it only to deploy code
- A corrected technical misstep (an initial Argo CD proposal with no Kubernetes target) replaced with the right tool for the actual architecture - a decision documented below rather than hidden

---

## Considered and Rejected

- **Argo CD for GitOps** - the original version of this project specified Argo CD, which synchronizes Git state to a Kubernetes cluster. This architecture has no Kubernetes target, so Argo CD would provide no function. Replaced with a GitHub Actions pipeline that enforces the same PR-reviewed, auditable deployment path without requiring infrastructure that doesn't exist here.
- **Multi-cloud (AWS + GCP) version of this project** - the underlying compliance requirement is about a *region* boundary, not a *vendor* boundary. Proving data residency within a single cloud is sufficient to answer the actual audit question, and is dramatically cheaper and faster to build and tear down than operating two cloud providers for the same proof.
- **Full AWS Organizations Landing Zone / Control Tower** - this project uses exactly two accounts and two narrowly-scoped SCPs to solve one specific problem (data residency enforcement). A full landing zone - account vending, OU structure, centralized logging at scale - solves a broader governance problem and remains a separate, larger candidate project rather than being folded in here.
- **cfn-nag as the CI policy tool** - cfn-nag lints CloudFormation, not Terraform plans. OPA is the correct tool for evaluating Terraform plan output against a custom cross-region rule.

---

## Time Budget

| Phase | Estimated Duration |
| --- | --- |
| Setup (tools, AWS Organizations + two accounts, Terraform backend) | Half day |
| Regional data planes (DynamoDB, S3, per-region Terraform module) | Half day |
| SCPs (cross-region write deny) | Half day |
| Lambda router + API Gateway | Half day |
| OpenTelemetry instrumentation | Half day |
| OPA policies + GitHub Actions pipeline | 1 day |
| Audit console (iterative) | 1 day |
| Demo scenario validation, all 4 scenarios | Half day |
| Documentation, diagram, proof capture, GitHub push | Half day |
| Clean-up + cost verification across both accounts | Half day |

**Total: roughly 5-6 focused days**

---

## Architecture Decisions Worth Documenting

- **Why mono-cloud, multi-region instead of multi-cloud**: the audit requirement is a region boundary, not a vendor boundary. Proving the same thing across two cloud providers adds cost and build time without adding any evidentiary value the auditor actually asked for.
- **Why GitHub Actions instead of Argo CD**: Argo CD's entire function is syncing Git state to a Kubernetes cluster; this architecture has no Kubernetes target, so Argo CD would be present without purpose. A standard CI/CD pipeline provides the identical audit property (reviewed PR then policy check then controlled apply) using tools that actually match the target infrastructure.
- **Why SCPs in addition to CI policy checks**: CI catches a violation before deploy, which is the first and cheapest line of defense - but it assumes CI itself was not bypassed or compromised. SCPs enforce the same rule at the AWS account level, independent of whether the application or the pipeline behaved correctly, which is the standard of proof an auditor actually wants.
- **Why OpenTelemetry spans carry residency metadata specifically**: generic application tracing shows that a request happened; tagging each span with `tenant_region` and `storage_region` turns the trace itself into the runtime evidence of compliance, which is the actual deliverable an auditor is asking for.
- **Why two accounts rather than a full landing zone**: this project answers one specific question - "did this tenant's data stay in its assigned region" - and two accounts with two scoped SCPs is the minimum infrastructure that proves it. Multi-account governance at scale is a different, broader problem, reserved as its own future project.
