---
name: review-judgment
description: "Reusable single-shot review judgment methodology for scoring prosecution and defense ledgers, verifying evidence, and emitting judge output. Use when ruling on review findings after prosecution and defense are available. DO NOT USE FOR: GitHub review intake routing, response-location policy, or fix execution ownership (keep those in Code-Review-Response.agent.md)."
---

<!-- platform-assumptions: markdown skill guidance for VS Code custom agents in Agent Orchestra; assumes the calling agent owns intake routing, categorization policy, and handoff to implementation. -->
<!-- markdownlint-disable-file MD041 MD003 -->

# Review Judgment

Reusable judgment method for a single referee pass over prosecution and defense.

## When to Use

- When prosecution findings and defense responses are both available
- When a judge must independently verify claims before ruling
- When a scored review summary and machine-readable ruling block are required
- When external review comments have already been converted into a prosecution ledger

## Purpose

Make one final, evidence-backed ruling per finding. The goal is not to split the difference between prosecutor and defense, but to decide whether the proposed change would improve the code and to record that decision in a format the pipeline can consume.

Prosecution ledgers are coverage-first by contract: prosecution reports every finding with a statable failure mode, including low-confidence and low-severity ones. The judge is the `filter of record` — expect a wide, uneven ledger as normal input, not a sign that prosecution failed. Filtering happens here, at judgment, not upstream.

## Single-Shot Judgment Workflow

1. Read the prosecution finding, including severity, points, citation, and failure mode.
2. Read the defense response and note whether it disproves, concedes, or cannot disprove the claim.
3. Verify the evidence independently.
4. Rule once: prosecution sustained or defense sustained.
5. Emit score, confidence, and structured output.

No rebuttal rounds. Uncertain items still need a ruling.

## Improvement Test

Reminder: because prosecution is coverage-first, this test will routinely see low-confidence and low-severity items — that is expected input, not noise to wave through. Rule on each the same way, evidence-first.

Ask this first for every item:

1. Will acting on this finding improve the code?

Outcomes:

- Yes -> accept the improvement
- No -> reject it
- Unclear even after verification -> reject it for now

Uncertainty is not a deferral bucket. If improvement cannot be shown with evidence, do not accept it.

## Independent Verification Expectations

Before sustaining a finding:

- Read the cited code, config, test, or document directly
- Confirm the claimed defect actually exists
- State what was verified, not just what the prosecutor said

When the cited evidence does not support the claim, sustain the defense and explain the mismatch clearly.

## Scoring Model

Severity maps to points as follows:

- `critical` or `high` -> 10 points
- `medium` -> 5 points
- `low` -> 1 point

Judges may override the prosecution severity when verification shows the impact is lower or higher than claimed.

Confidence guidance:

- `high` -> direct structural proof, test output, or explicit code evidence
- `medium` -> evidence leans one way but is not fully conclusive
- `low` -> honest uncertainty after reasonable verification

## Score Summary Output

Emit a score table after ruling all findings.

```markdown
### Adversarial Review Score Summary

| Finding     | Pass | Prosecution (severity, pts) | Defense verdict | Ruling                   | Confidence | Points    |
| ----------- | ---- | --------------------------- | --------------- | ------------------------ | ---------- | --------- |
| F1: {title} | {N}  | {severity} ({pts} pts)      | conceded        | ✅ Sustained             | high       | P+{pts}   |
| F2: {title} | {N}  | {severity} ({pts} pts)      | disproved       | ❌ Defense sustained     | medium     | D+{pts}   |
| F3: {title} | {N}  | {severity} ({pts} pts)      | disproved       | ✅ Prosecution sustained | high       | D-{2×pts} |

**Totals**

- Prosecutor: {sum of sustained prosecution points} pts ({N} findings sustained)
- Defense: {net points after rejected-disproof penalties} pts
- Judge rulings: {total} ({N} pending user scoring)
```

Use `—` in the Pass column when the prosecution mode does not carry a pass number.

## Structured Judge Output

### Sentinel emission (issue #441, D-new-4)

**Immediately after the judge ruling is finalized** and before any pipeline-metrics persistence,
write an idempotent sentinel PR comment for the PR being reviewed:

```text
<!-- review-judge-produced-{PR} -->
```

This sentinel is separate from the judge-rulings comment. On GitHub, post it via `gh pr comment {PR} --body '<!-- review-judge-produced-{PR} -->'`. Use upsert semantics: if the comment already exists (idempotency check via `gh pr view {PR} --json comments`), skip the write.

**Ordering rule**: sentinel comment → judge-rulings comment. The sentinel must be written first so that the warn-only hook can detect "review completed but credit not yet written" during the window between sentinel emission and PR-body update.

**SMC-16 governance**: the sentinel marker `<!-- review-judge-produced-{PR} -->` is governed by SMC-16. See `Documents/Design/session-memory-contract.md`. Both Copilot and Claude judge runs write this sentinel; Code-Conductor reads it via the warn-only hook synthesis path.

### Judge-rulings comment

After the sentinel, emit the `judge-rulings` block in the same PR comment as the Markdown score summary:

```yaml
<!-- judge-rulings
- id: F1
  judge_ruling: sustained
  judge_confidence: high
  points_awarded: P+10
- id: F2
  judge_ruling: defense-sustained
  judge_confidence: medium
  points_awarded: D+5
-->
```

Keep the Markdown score summary and the `judge-rulings` block together in the same response payload. On GitHub, keep them in the same PR comment rather than splitting them across separate comments. **This comment does not include `<!-- code-review-complete-{PR} -->`** — that marker is retired as of issue #441 Step 11; Code-Conductor reads `credits[]` from the `<!-- pipeline-metrics -->` PR body block directly. **This comment does not include pipeline-metrics body emission** — that is owned by Code-Conductor's `## Pipeline Metrics` emitter at PR creation time.

### Phase-containment emission

In the same PR comment as the `<!-- judge-rulings ... -->` block, emit one `<!-- phase-containment-{PR} -->` block per sustained finding (`judge_ruling: sustained`):

- `finding_key`: `code-review:{stable_finding_key}`
- `introduced_phase`: set by explicit agent judgment — no default; reason which phase originated this defect
- `catchable_phase`: set by explicit agent judgment — no default; reason which phase was the earliest this defect could have been caught
- `caught_stage: code-review`
- `escape_distance`: recomputed as `3 - ordinal(catchable_phase)` (code-review projection = 3; phase ordinals: experience=0, design=1, plan=2, implementation=3)
- `severity`, `systemic_fix_type`, `category`: carry forward from the finding
- `apparatus_meta: false` unless a stated criterion justifies `true`; when `apparatus_meta: true`, the entry is audited

**Setter rule**: `catchable_phase` and `introduced_phase` must each be set by explicit agent judgment with no default — the agent must reason about which phase was the earliest in which this specific defect was catchable. Validate each block against `skills/calibration-pipeline/schemas/phase-containment.schema.json`.

**Emission check (hub maintainers only)**: after posting the `judge-rulings` PR comment with its phase-containment blocks, run `pwsh ./.github/scripts/phase-containment-emission-check.ps1 -Pr {N}` and treat its output as advisory — warn-only, never blocking. The repo-relative script path does not resolve from a consumer repo's CWD, so this nudge applies only when working in the Agent Orchestra hub repo itself; see the script header for the full contract.

**Detective-sample extension**: the Code-Critic detective-sample (from `agents/Code-Critic.agent.md:110`) is extended to sample `apparatus_meta: true` entries and `catchable_phase == caught_stage` entries for plausibility review.

Field values:

- `judge_ruling`: `sustained` or `defense-sustained`
- `judge_confidence`: `high`, `medium`, or `low`
- `points_awarded`: `P+{pts}`, `D+{pts}`, or `D-{2×pts}`

## General Judgment Workflow

### Default Path

- Verify the finding
- Rule on it
- Categorize it according to the calling agent's policy
- Stop after emitting the judgment output

### Evidence-First Rejection

When rejecting, cite the reason explicitly:

- The code contradicts the finding
- Tests or types already guarantee the claimed invariant
- The documented design makes the proposed change harmful
- The reviewer's cited evidence is factually wrong

### Escalation Boundary

Judgment does not implement fixes. It produces the ruling and the evidence package needed for the owning orchestrator to route accepted work.

## Related Guidance

- Load `adversarial-review` for prosecution and defense methodology
- Load `code-review-intake` when GitHub review retrieval and ledger construction are the main problem

## Gotchas

| Trigger                                   | Gotcha                                                   | Fix                                                          |
| ----------------------------------------- | -------------------------------------------------------- | ------------------------------------------------------------ |
| The judge repeats the prosecutor verbatim | The ruling becomes a rubber stamp instead of independent | Read the cited artifact directly and state what was verified |

| Trigger                             | Gotcha                                                         | Fix                                                                |
| ----------------------------------- | -------------------------------------------------------------- | ------------------------------------------------------------------ |
| A ruling omits the `judge-rulings` block | Downstream consumers can miss completion or fail to route cleanly | Emit the `judge-rulings` block immediately after the score summary in the same payload; ensure the `<!-- review-judge-produced-{PR} -->` sentinel was written as a separate PR comment before |

## Post-Judge Disposition Gate

### Purpose

After the judge emits its rulings (sentinel + judge-rulings comment), the owning parent agent runs the review-disposition engagement gate over the judge-sustained findings. This prevents cognitive surrender at the PR code-review verdict point: the engineer must consciously disposition each sustained finding rather than having the agent assume outcomes.

This gate is owned by the calling workflow (e.g. `/orchestra:review-judge`, `/orchestra:review`), not by this skill's judgment pass. The judgment pass ends with the judge-rulings comment. Disposition begins immediately after.

### When to Run

- After the `<!-- review-judge-produced-{PR} -->` sentinel is confirmed written
- Over the judge-sustained findings from the `<!-- judge-rulings ... -->` block
- Only for sustained findings (`judge_ruling: sustained`); defense-sustained findings (`judge_ruling: defense-sustained`) are skipped silently (not disposition-gated)

### Classification

For each judge-sustained finding, run the solution-authoring classification gate (`skills/solution-authoring/SKILL.md § Rule: Classification gate`) to determine whether it is **load-bearing** or **routine**.

A finding is **load-bearing** iff all three legs pass:

1. **Reversibility** — acting on this finding would change a published or durable artifact (source file, test, config, doc, or skill).
2. **Non-inheritance** — no specific inherited artifact (prior design decision, existing AC, approved plan statement, locked methodology rule) already settles the required action. The agent MUST attempt to cite one before declaring non-inheritable.
3. **Audit-plausibility** — the agent can write a substantive `disposition_rationale` sentence.

Failing any leg collapses the finding to **routine**. The tier rule from `solution-authoring § Applying the gate to adversarial-review dispositions` applies: load-bearing adversarial-review dispositions use the **escalation tier** decision brief; routine findings are recorded silently.

### Stable Finding Key

Before the gate fires, compute a `stable_finding_key` for each finding. This key must survive re-reviews of the same PR. Use the first available:

1. **GitHub comment ID** — if the finding originated from a GitHub review comment, use its comment ID as the key. A comment that yields a single finding keeps the tier-1 key `gh-{comment_id}` — unchanged, and backward compatible with dispositions persisted before this discriminator existed. When one comment yields multiple distinct findings (the code-review-intake skill's split rule — see `skills/code-review-intake/SKILL.md`), each finding's key becomes `gh-{comment_id}-{normalized-title-hash[:8]}`, reusing tier 2's normalization convention below to disambiguate findings sharing a comment ID.
2. **file:line:hash** — normalize the finding title (lowercase, remove punctuation, replace spaces with hyphens), then form `{relative_file}:{line}:{normalized-title-hash[:8]}` where hash is the first 8 hex chars of a deterministic hash of the normalized title.
3. **finding_id fallback** — if neither is available, use the sequential `finding_id` (e.g. `F1`) with a `warn:` prefix to signal instability: `warn:F1`.

The `stable_finding_key` is what the resume-read mechanism uses to detect prior dispositions across re-reviews of the same PR (see § Stable-Key Resume below).

### `reviewer_source` Lookup Order (GitHub-Sourced Findings Only)

This lookup order applies only to findings that originated from an external GitHub review comment. Pipeline-native findings (local prosecution/defense/judge findings) never enter this lookup procedure — the disposition-recording sites below write `reviewer_source: local` directly for those findings, without evaluating any of the three tiers.

Both disposition-recording sites below (§ Routine Findings and § Load-Bearing Findings) write a `reviewer_source` field. For GitHub-sourced findings, resolve its value in this order:

1. **In-context intake ledger** — when the session is continuous with the GitHub-intake pass that built the finding, read the `reviewer_source` value the intake skill (`skills/code-review-intake/SKILL.md`) already recorded for this finding.
2. **`gh api` re-derivation** — otherwise (standalone or resumed judge pass), extract the `comment_id` embedded in the finding's `stable_finding_key` and re-derive the reviewer identity via `gh api`, trying the PR-review-comment, issue-comment, and review endpoints in turn. Parse rule: the `comment_id` is the numeric run immediately after the `gh-` prefix, up to the next `-` or end of string; this covers both the single-finding `gh-{comment_id}` key shape and the multi-finding `gh-{comment_id}-{hash}` key shape identically. Normalize the result per the intake skill's rule: `lowercase(author.login)` with a trailing `[bot]` suffix stripped, sourced from the author's `.login` field only (never display name), written as a quoted scalar, with the same reserved-value collision escape (a real login colliding with `local` or `unresolved` is recorded as `ext-{login}`).
3. **`unresolved` sentinel** — on any failure (comment deleted, API error, no comment ID embedded in the key to re-derive from), write the sentinel `unresolved`. Never write `local` on lookup failure — `local` is reserved exclusively for pipeline-native (non-GitHub-sourced) findings, which are written directly per the guard above and never fall through to this sentinel.

### Routine Findings — Silent Recording

For routine findings, the agent records the disposition silently in the `review-dispositions-{PR}` accumulator without firing an `AskUserQuestion`. Use `schema_version: 3` (current emission format); write `severity`, `stage`, and `reviewer_source` (the reviewer identity or class that produced the finding — use `local` for pipeline-native prosecution/defense/judge findings; external identities are resolved per § `reviewer_source` Lookup Order above) for all entries, and include `ac_cross_check` for any `dismiss` or `defer` entry with severity ≥ medium:

> **Pre-condition**: for any `dismiss` entry with severity ≥ medium, run the AC cross-check (see § AC Cross-Check — Blocking Pre-Condition) before writing this entry.

```yaml
- stable_finding_key: "src/foo.ts:42:null-check-missing-a1b2c3d4"
  finding_id: F2
  pass: 1
  disposition: incorporate   # or dismiss — agent's judgment based on judge ruling
  classification: routine
  severity: medium           # v3: required field
  stage: code-review         # v3: required field
  reviewer_source: local     # v3: writer always emits this field (writer obligation); the reader/consumer treats an absent field as local for backward compat with pre-v3 entries (reader-semantics fallback) — local is reserved for pipeline-native findings; external identities resolve per § reviewer_source Lookup Order
  disposition_rationale: "Trivial null-guard already required by the existing type contract; no maintainer choice required."
  artifact_citation: "src/types/index.ts:18 (NonNullable<T> constraint)"
```

The agent chooses `incorporate` or `dismiss` based on the judge ruling direction. Routine findings do not fire the gate; they feed directly into the accumulator.

### Load-Bearing Findings — AskUserQuestion

For load-bearing findings, render an **escalation-tier decision brief** (three required elements, all present before the option list):

1. **Concrete element → current state**: what the current code/artifact actually does, with evidence (file:line or artifact citation from the finding).
2. **Decision setup → the conflict**: why this finding's proposed change conflicts with or extends beyond the current state.
3. **Conditional misconception → customer failure mode**: the concrete failure the engineer would cause by taking the wrong path.

Then fire `AskUserQuestion` with options:

- `Incorporate — apply the fix` (Recommended if prosecution was sustained on strong evidence)
- `Dismiss — the finding does not warrant a change`
- `Escalate — this needs a design decision or a separate issue`
- `Decline engagement — proceed without classification`

Capture the engineer's choice verbatim.

> **Pre-condition**: if the engineer chooses `dismiss` with severity ≥ medium, run the AC cross-check (see § AC Cross-Check — Blocking Pre-Condition) before writing this entry.

Record as (v3 format — include `severity`, `stage`, `reviewer_source`, and `ac_cross_check` for dismiss/defer entries with severity ≥ medium):

```yaml
- stable_finding_key: "src/auth/session.ts:88:token-expiry-not-checked-b7c1a2f3"
  finding_id: F1
  pass: 2
  disposition: incorporate   # or dismiss or escalate per engineer choice
  classification: load-bearing
  severity: high             # v3: required field
  stage: code-review         # v3: required field
  reviewer_source: local     # v3: writer always emits this field (writer obligation); the reader/consumer treats an absent field as local for backward compat with pre-v3 entries (reader-semantics fallback) — local is reserved for pipeline-native findings; external identities resolve per § reviewer_source Lookup Order
  disposition_rationale: "Engineer chose incorporate: the expiry check was confirmed missing and the fix is bounded to one function."
```

### Escalate Semantics

When an engineer selects `Escalate`:

1. Record `disposition: escalate` in the entry.
2. Emit a concise escalation note inline (not a structured question): `Finding {finding_id} escalated — recommend filing a follow-up issue for: {finding title}. Proceeding without implementing this finding.`
3. Do NOT implement the finding in the current PR. The current work continues; the escalated finding is noted for tracking.
4. Record the `escalate` outcome faithfully in `review-dispositions-{PR}` and in the L0 gate-decision token.

### AC Cross-Check — Blocking Pre-Condition

Before writing any entry with `disposition: dismiss` or `disposition: defer` **and** `severity` ≥ medium — whether the entry originates from a code-review finding (`stage: code-review`) or a CE Gate defect deferral (`stage: ce`) — the agent MUST complete an AC cross-check:

1. Call `Get-AcTermsFromIssue -IssueNumber {parent_issue}` to extract behavioral AC terms.
2. Call `Get-StructuralVerdict -Finding {finding} -PrFileSet {pr_files} -AcRefs {ac_refs} -RepoRoot {repo_root} -AcTerms {ac_terms}` to obtain the `ac_cross_check` object.
3. Write the returned `ac_cross_check` object into the disposition entry.

**This pre-condition is blocking.** The gate MUST NOT commit a `dismiss` or `defer` entry with severity ≥ medium that has a null or absent `ac_cross_check`. If `Get-AcTermsFromIssue` returns an empty array (no AC section found), the cross-check still runs — pass `@()` as `-AcTerms`; the verdict's `ac_cross_check.source` will be `no-ac-section` and `routed` will be `defer`.

**Low-severity exemption.** Entries with severity `low` are exempt from this pre-condition (the validator also exempts them). Record them without `ac_cross_check`.

**`Add-FollowUpIssue` guard.** When the cross-check routes to `defer` and the agent calls `Add-FollowUpIssue` to file a follow-up issue, it MUST pass the `ac_cross_check` outcome as part of the issue body. Include a fenced YAML block in the body:

```yaml
ac_cross_check:
  file_arm: {bool}
  term_arm: {bool}
  result: {matched-high|matched-ambiguous|no-match}
  source: {issue|pr-body|no-ac-section}
  routed: defer
```

This ensures the follow-up issue carries AC-provenance for the deferral decision, which is the AC4 contract.

### Legitimate Partial-AC Defer — Loud Guard

When the AC cross-check returns `routed: defer` (because `result: no-match` or `source: no-ac-section`), the agent has confirmed that this finding genuinely lacks plan AC coverage. **Silently recording a `defer` entry at this point is the exact anti-pattern this feature was built to prevent.**

The agent MUST follow this sequence instead:

1. **Emit a loud inline note** (not `AskUserQuestion` — this is a guard, not a user question): `⚠️ Finding {finding_id} deferred without AC coverage (ac_cross_check.result: {result}) — mandatory proposal required.`

2. **Enter a mandatory proposal** into the `§2e Filing Approval Gate` batch (`skills/safe-operations/SKILL.md` § 2e), pre-checked and recommended-approve, annotated `AC-uncovered defer`. The canonical title uses `ConvertTo-CanonicalFollowupTitle`. The proposal body MUST include the finding title, the judge ruling, and the `ac_cross_check` YAML block — this payload travels into the durable drop record if the maintainer drops the proposal. This is mandatory regardless of the finding's classification tier — routine findings that lack AC coverage still enter the gate as a proposal.

3. **Record in the accumulator** with `disposition: defer`, the `ac_cross_check` object, and `disposition_rationale` that cites the `no-match`/`no-ac-section` outcome and references the gate proposal (and the resulting issue URL once the maintainer approves it and it is filed).

The loud guard does not apply when `routed: force-accept` (high-confidence AC match) or `routed: disposition-gate` (ambiguous match fires `AskUserQuestion` normally). It applies only to the `routed: defer` arm.

**Low-severity exemption applies here too**: findings with severity `low` are exempt from this guard (the low-severity exemption from the blocking pre-condition applies throughout this section).

### L0 Gate-Decision Tokens

For each finding that was gate-classified (routine or load-bearing), emit an L0 gate-decision token per `skills/solution-authoring/schemas/gate-decision-token.schema.json`:

```yaml
decision_id: "{stable_finding_key}"
phase: review
outcome: asked          # 'asked' for load-bearing, 'gate-fails' for routine
classification: load-bearing   # or routine
window_position: review-disposition
timestamp: "{ISO-8601 UTC}"
pull_request_number: {PR}   # NOT issue_number
skip_reason: "routine-finding"   # omit when outcome=asked
```

Write each token to the authoritative L0 location per `skills/solution-authoring/SKILL.md` § L0 Gate Token: `/memories/session/gate-events-{session_key}.jsonl` (fallback: `.copilot-tracking/gate-events.jsonl`) as a single JSON line per the existing L0 emission pattern.

### Stable-Key Resume

At the start of the disposition pass, call `Read-EngagementRecords -Phase review -PullRequestNumber {PR}` (from `.github/scripts/lib/frame-engagement-record-core.ps1`). If a prior `engagement-record-review-{PR}` exists, extract its `load_bearing_decisions[].decision_id` values. These are `stable_finding_key` values of previously-gate-fired findings.

For each finding in the current judge-sustained set, check whether its `stable_finding_key` appears in the prior record:

- **Match found** → `same-decision-resume` skip: reuse the prior `engineer_choice`, log `Reusing prior {stable_finding_key}: {engineer_choice}`, do not fire `AskUserQuestion`.
- **No match** → run the gate normally.

This enables re-review of a PR without re-asking for findings already dispositioned.

### Persistence — Ordering

Write in this order (atomic marker first, engagement-record second):

1. **`<!-- review-dispositions-{PR} -->`** — Post as a PR comment. Payload: `schema_version: 3`, `passes_run: [...]`, `entries: [...]` (all findings, routine and load-bearing, one entry per finding). v2 added per-entry `severity`, `ac_cross_check`, and `stage` fields; v3 adds per-entry `reviewer_source` (the reviewer identity or class — `local` for pipeline-native findings; external identities resolve per § `reviewer_source` Lookup Order above). This is the atomic per-finding record.

   ````text
   <!-- review-dispositions-{PR} -->

   ```yaml
   schema_version: 3
   passes_run: [1, 2, 3, 4, 5]
   entries:
     - stable_finding_key: "..."
       pass: 1
       disposition: incorporate
       classification: routine
       severity: medium
       stage: code-review
       reviewer_source: local   # or an origin-derived value (e.g. "jdoe", resolved per § reviewer_source Lookup Order) when the finding came from an external reviewer
       disposition_rationale: "..."
       ac_cross_check:
         file_arm: false
         term_arm: true
         result: matched-high
         ac_ref: "- the AC line that matched"
         source: issue
         routed: force-accept
   ```
   ````

   > **v3 per-entry requirements** (carried over unchanged from v2): For entries with `disposition: dismiss` or `disposition: defer` and `severity` ≥ medium, `ac_cross_check` is required. The `ac_cross_check` object records which arms ran (`file_arm`, `term_arm`), the result tier (`matched-high | matched-ambiguous | no-match`), the matched AC reference if any, the source, and the routing outcome. Legacy `schema_version: 1` entries are exempt from this check. `artifact_citation` covers non-AC inherited artifacts; `ac_cross_check.ac_ref` is the AC-specific channel.
   >
   > **`stage` field values**: The `stage` field records which pipeline stage produced this entry: `code-review` for the post-judge disposition gate, `ce` for CE Gate defect deferral. Both stages use the same `ac_cross_check` pre-condition at severity ≥ medium.
   >
   > **In-session schema audit (before posting)**: Before posting the `review-dispositions-{PR}` comment to the PR, run a warn-only schema check using `.github/scripts/lib/review-dispositions-validator-core.ps1 -PullRequestNumber {PR} -InMemoryMarkers @($rawMarkerText)`. Surface any `findings` as warnings. This catches v3 schema violations (e.g., missing `ac_cross_check` on dismiss/defer entries at severity ≥ medium) before the marker is committed to the PR timeline. The validator is warn-only and never blocks posting.

2. **`<!-- engagement-record-review-{PR} -->`** — Post as a separate PR comment (not the same comment as review-dispositions). Payload follows `skills/engagement-record-emission/SKILL.md` shape at `schema_version: 4`, `phase: review`. Load-bearing findings that fired `AskUserQuestion` appear in `load_bearing_decisions[]` with their `engineer_choice` and `audit_rationale`. Routine findings do not appear in the engagement-record.

   The engagement-record carries the `same-decision-resume` identity; the review-dispositions carries the per-finding outcome record. Never merge the two into a single comment.

### SMC References

- **SMC-19** — `finding_dispositions` is design-only (issue-keyed on `design-phase-complete`). This section's `review-dispositions` is a distinct, PR-keyed path.
- **SMC-23** — governs `review-dispositions-{PR}` + `engagement-record-review-{PR}` survival, write path (PR comments), and cross-tool fungibility.
- **SMC-20** — extended to include `review` phase; governs `engagement-record-review-{PR}` cross-session resume semantics.

### Gotcha: Gate fires post-judge, not inside judge

The classification gate fires in the **owning parent workflow** after receiving the judge output. The judge body (this skill's judgment pass) ends at the judge-rulings comment. Do not add gate logic inside the judge's verification or scoring steps — doing so would conflate two distinct phases and make re-running the judge independent of dispositions impossible.
