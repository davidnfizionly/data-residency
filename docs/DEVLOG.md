# DEVLOG

Real problems, root causes and fixes, written as they occur. Corrections of earlier claims also go here.

## Phase 1 - Budget without alerts

- What: the 5 USD monthly budget is created with no notification and no e-mail subscriber. It tracks spend only (credits and refunds excluded).
- Consequence: no alert fires if spend passes 5 USD. Spend has to be checked manually in Budgets and Cost Explorer, which lag up to 24 hours.
- Decision record: ADR-001 in `docs/DECISIONS.md`.

## Phase 1 - Reference images swept into the first commit

- What: two AWS reference architecture images (copyright AWS, kept as diagram style references) were in `docs/style-reference/` and were included by `git add -A` in the first commit.
- Root cause: a blanket `git add -A` without reviewing untracked files first.
- Fix: the files were removed from the index, the directory was added to the local git exclude list, and the unpushed commit was amended. Commits now stage reviewed paths only.

## Phase 2 - SCP creation failed right after the organization was created

- What: the first apply created the organization and both member accounts, then failed on both SCPs with `AWSOrganizationsNotInUseException: Your account is not a member of an organization`, about 30 seconds after `CreateOrganization` succeeded.
- Root cause: eventual consistency in AWS Organizations. The organization existed (SCP policy type showed `ENABLED` on the root a minute later) but `CreatePolicy` did not see it yet.
- Fix: a fresh plan showed only the 4 missing resources (2 policies, 2 attachments); the second apply succeeded. No code change. Output in `proof/03-org-apply.txt`.

## Phase 2 - Tenant-tag deny tested only without tags so far

- What: `OrganizationAccountAccessRole` trusts `sts:AssumeRole` only, not `sts:TagSession`, so the SCP tests in `proof/04-scp-deny-tests.txt` cover the region lock and the "no tag" case. The "wrong tag" case (EU tenant written into the US account) needs the regional writer role, whose trust allows session tags. It is tested in Phase 4.
