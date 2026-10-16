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

## Phase 4 - Every write failed with "identity.expiration.getTime is not a function"

- What: the first router deployment answered HTTP 500 on every `POST /records`, for EU and US tenants alike. The spans showed `sts.AssumeRole OK` then `dynamodb.PutItem ERROR`.
- Root cause: the router caches the assumed writer-role credentials and stored `expiration` as a number (milliseconds). AWS SDK for JavaScript v3 expects a `Date` object there and calls `getTime()` on it before signing.
- Fix: keep `Expiration` as the `Date` returned by STS and compare with `getTime()`. Redeployed through the auto-apply gate (1 change, Lambda code only). Rerun in `proof/08-router-cli-tests.txt`. The failed attempts stay visible in the trace history as `outcome: error`.

## Phase 4 - Redaction regex masked part of a hash

- What: the test output redaction replaced any 12-digit run with `<account-id>`, which also hit 12 consecutive digits inside the registry SHA-256.
- Fix: the regex now requires a non-alphanumeric boundary on both sides, in the test script and in the router's error-message masking.

## Phase 4 - Tenant-tag SCP case now tested

- The deliberate misroute (EU tenant forced to us-east-1 by direct invocation) assumed `data-residency-writer-us` with session tag `tenant_region=eu`; the US account SCP denied `dynamodb:PutItem` explicitly. This closes the gap noted in Phase 2.

## Phase 5 - First pipeline run could not assume the apply role

- What: the first run on `main` failed at `configure-aws-credentials` with `Not authorized to perform sts:AssumeRoleWithWebIdentity`.
- Root cause: the trust policies expected the name-based subject `repo:davidnfizionly/data-residency:ref:refs/heads/main`, but GitHub issues an immutable subject for this repository that includes the numeric owner and repository IDs (`repo:davidnfizionly@210562805/data-residency@1422220770:...`), as shown by `GET /repos/{repo}/actions/oidc/customization/sub`.
- Fix: the trust policies now use the immutable subject prefix. This is also stricter: a recreated repository with the same name gets a new ID and cannot assume the roles.
- Side effect: the trust update was refused by the auto-apply gate because the plan JSON repeats each role's inline policies under `aws_iam_role.<name>.inline_policy`, an address not listed in ADR-015. The two mirror addresses were added to ADR-015; the gate itself was not relaxed.

## Phase 6 - Organization and policy IDs visible in the console

- What: the first headless capture of the violation simulator showed the SCP denial message with the organization ID (`o-...`) and policy ID (`p-...`) in clear. The router and the test scripts masked only 12-digit account IDs.
- Root cause: the masking regex covered account IDs only; AWS denial messages also carry the SCP ARN.
- Fix: organization, root and policy IDs are now masked in the console proxy (everything shown in the browser) and in the router (span messages and API responses). The capture was deleted and retaken, and every capture is opened and checked before it is added.

## Phase 6 - Compliance history out of order

- What: the timeline listed pull requests below older commits.
- Root cause: commits carry the author's local offset (`+03:00`) and pull requests carry UTC (`Z`); the entries were sorted as strings.
- Fix: sort by parsed timestamp.

## Phase 6 - Fresh trace not visible right after a write

- What: after "Write a test record now", the newest trace was sometimes missing from the evidence list.
- Root cause: spans reach CloudWatch Logs a few seconds after the Lambda writes them; a fixed 4-second wait was not always enough.
- Fix: the console polls until the trace ID returned by the write appears (up to 30 seconds). The root span is also listed first, since spans that start in the same millisecond had no stable order.

## Phase 6 - Personal e-mail written into public history by GitHub merges

- What: after pull requests #1 and #4 were merged with "Rebase and merge", the two resulting commits on `main` had the account's primary personal e-mail as committer, and the "Update branch" button on #4 created a merge commit with the same address as author. The repository is public, so the address was visible in the history.
- Root cause: GitHub writes commits created on its side (rebase merges, branch updates) with the account's primary e-mail unless "Keep my email addresses private" is enabled. The local pre-push guard only sees commits pushed from this machine, so it could not catch them.
- Fix:
  - "Keep my email addresses private" and "Block command line pushes that expose my email" were enabled on the GitHub account.
  - The two commits on `main` were rewritten with the noreply committer address (same trees, new SHAs), force-pushed once with admin enforcement and force pushes enabled only for that push, and the full branch protection was restored right after (14:36:09 UTC).
  - The merged branches `phase6/audit-console` and `proof/pipeline-first-runs` were deleted.
  - Check after the fix: every commit on `main` has the noreply address as author and committer; no other branch exists.
- Remaining exposure: GitHub keeps `refs/pull/4/head` (read-only) pointing at the branch-update merge commit, and old commit SHAs can stay reachable by direct URL until GitHub's garbage collection. Only GitHub Support can purge them.
- Prevention: after every merge, the commits on `main` are checked through the API for any non-noreply author or committer.

## Phase 7 - Scenario script defects found on the first run

- What: the first run of the audit walkthrough printed no "last routing commit" and reported the access-log object as `None`; the SCP scenario printed a jq error before each result.
- Root causes: `git log -- infra/stack/tenants.json` ran from `infra/stack`, so the path was resolved relative to that directory; the AWS CLI auto-paginates `list-objects-v2` and drops `KeyCount`; `aws lambda invoke ... /dev/stdout --query StatusCode` appended the status code to the payload stream.
- Fix: run git from the repository root, count `Contents` instead of `KeyCount`, write the payload to a temporary file. Both scenarios were rerun; the outputs in `proof/13` and `proof/15` are from the second run.

## Phase 7 - What the policy check cannot see

- The scenario 4 change (router code sending every write to us-east-1) passed the OPA check, as expected: the policy evaluates the Terraform plan, and the tenant registry did not change. The violation was stopped at runtime by the US account SCP (every EU write refused, nothing stored) and corrected by a `git revert` merged through the same pipeline. This is the reason for the second, account-level layer.

## Phase 8 - Console role switch impossible for the EU account capture

- What: the capture of the EU PII table needed the AWS console in the EU member account, but the console session was the management account's root user, and the root user cannot switch roles.
- Fix: no IAM user or password was created. A one-off console sign-in link was built through the AWS federation endpoint from a 1-hour `OrganizationAccountAccessRole` session in the EU account, restricted by a session policy to DynamoDB configuration reads (`Describe*`, `List*`, metrics and alarms; no `GetItem`, `Scan` or `Query`). The link was written to a local file outside the repository, never printed, and had to be used within 15 minutes; the session expired on its own at 16:22 UTC, so there was nothing to delete afterwards.
