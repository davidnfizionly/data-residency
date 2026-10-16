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
