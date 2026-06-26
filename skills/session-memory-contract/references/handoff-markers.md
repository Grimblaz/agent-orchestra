<!-- markdownlint-disable-file MD013 -->

# Cross-tool Handoff Markers

Durable GitHub comment markers used by Agent Orchestra for phase handoffs, smart resume, engagement records, and credit ledger. Markers are HTML comments written to GitHub issue or PR threads; because they live on the issue, work resumes across sessions without losing context.

Row-level survival and fallback semantics: [../SKILL.md](../SKILL.md) (session-memory-contract).  
Persistence rationale: [../../../Documents/Design/session-memory-contract.md](../../../Documents/Design/session-memory-contract.md).

## Active Marker Families

- `<!-- experience-owner-complete-{ID} -->` — upstream framing complete
- `<!-- design-phase-complete-{ID} -->` — technical design complete
- `<!-- engagement-record-experience-{ID} -->` — durable engagement audit for /experience phase: load-bearing decisions, audit rationale, articulation text persisted alongside the experience-owner-complete marker for cross-session decision memory (SMC-20)
- `<!-- engagement-record-design-{ID} -->` — durable engagement audit for /design phase: load-bearing decisions persisted alongside the design-phase-complete marker; consumed by solution-authoring's same-decision-resume rule on phase re-entry (SMC-20)
- `<!-- engagement-record-plan-{ID} -->` — durable engagement audit for /plan phase: load-bearing decisions persisted alongside the plan-issue marker; consumed by solution-authoring's same-decision-resume rule on phase re-entry (SMC-20)
- `<!-- engagement-record-orchestration-{ID} -->` — durable engagement audit for orchestration touchpoint (`scope-classification`): persisted as an issue comment when scope-classification resolves; payload Markdown mirror co-located in the comment; consumed by solution-authoring's same-decision-resume rule on Code-Conductor re-entry (SMC-20)
- `<!-- engagement-record-review-{PR} -->` — durable engagement audit for /orchestra:review and /orchestra:review-judge phases: load-bearing review-finding dispositions persisted as a PR comment after the post-judge disposition gate completes; consumed by same-decision-resume on re-review of the same PR (SMC-20, SMC-23, schema_version 4)
- `<!-- review-dispositions-{PR} -->` — per-finding disposition record for PR code-review verdicts; one entry per judge-sustained finding carrying stable_finding_key, pass, disposition (incorporate|dismiss|escalate), classification, and disposition_rationale (SMC-23)
- `<!-- design-issue-{ID} -->` — durable design snapshot handoff used for D9 pause/resume and full-pipeline smart resume
- `<!-- plan-issue-{ID} -->` — approved plan persisted
- `<!-- frame-credit-ledger-{PR} -->` — warn-only frame credit-ledger comment posted by the pre-PR hook (sub-issue #429 of frame umbrella #425); idempotently upserted on every PR after `gh pr create`
- `<!-- review-judge-produced-{PR} -->` — sentinel written by the judge (both Copilot and Claude) immediately after the ruling finalizes, before pipeline-metrics persistence; the warn-only hook detects this to synthesize a `not-persisted` review credit when the PR body carries no review credit yet (SMC-16)
- `<!-- credit-input-{port}-{ID} -->` — deferred-emission marker written by pipeline-entry agents (Experience-Owner, Solution-Designer, Issue-Planner) immediately after their completion marker; payload is a `yaml` fenced block carrying `{ port, adapter, evidence }`; harvested by Code-Conductor at PR-creation time to emit the corresponding credit row (SMC-17)

## Retired Markers

- `<!-- code-review-complete-{PR} -->` — retired in issue #441 Step 11; Code-Conductor reads `credits[]` from the PR-body pipeline-metrics block instead
