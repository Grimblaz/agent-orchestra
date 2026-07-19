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

**POST-FIX-SCOPED**: when this verification pass follows post-fix targeted prosecution with mutation-tested verification, judgment coverage extends to every branch the fix commit modified, per the canonical post-fix scope constraint in `skills/validation-methodology/references/review-reconciliation.md`. This note does not apply to a non-post-fix (main-review) judgment pass.

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

In the same PR comment as the `<!-- judge-rulings ... -->` block, emit one `<!-- phase-containment-{PR} -->` block per sustained finding (`judge_ruling: sustained`). The two block families are different shapes and are not interchangeable: `judge-rulings` (above) stays **bare** — one unclosed `<!-- judge-rulings ... -->` comment — while `phase-containment` is always **paired** — a self-closed `<!-- phase-containment-{PR} -->` open tag followed by plain-text YAML fields and a separate `<!-- /phase-containment-{PR} -->` close tag, because the close tag powers `Get-PhaseContainmentBlock`'s pair-matching malformation detection (issue #772 D6). **Scope boundary**: this section and its Observer variant below document the block *shape* only — routing a given finding's emission to the shared `Add-JudgeRulingsBlock`/`Get-PhaseContainmentBlock` helper machinery is deferred to AC6, not covered here.

- `finding_key`: `code-review:{stable_finding_key}`
- `introduced_phase`: set by explicit agent judgment — no default; reason which phase originated this defect
- `catchable_phase`: set by explicit agent judgment — no default; reason which phase was the earliest this defect could have been caught
- `caught_stage: code-review`
- `escape_distance`: recomputed as `3 - ordinal(catchable_phase)` (code-review projection = 3; phase ordinals: experience=0, design=1, plan=2, implementation=3)
- `severity`, `systemic_fix_type`, `category`: carry forward from the finding
- `apparatus_meta: false` unless a stated criterion justifies `true`; when `apparatus_meta: true`, the entry is audited
- `appended_at`: stamp the current UTC instant in the strict `yyyy-MM-ddTHH:mm:ssZ` form (863 M1 fix) — this block is hand-authored directly into the PR comment (no script primitive writes it on this surface), so the judge/agent authoring the block is responsible for stamping this field itself

A fully literal canonical example, for a sustained code-review finding on PR 879:

```markdown
<!-- phase-containment-879 -->
finding_key: code-review:gh-1234
introduced_phase: implementation
catchable_phase: implementation
caught_stage: code-review
escape_distance: 0
severity: high
systemic_fix_type: instruction
category: security
apparatus_meta: false
appended_at: 2026-07-18T22:20:00Z
<!-- /phase-containment-879 -->
```

#### Observer emission variant (post-review-observer)

`reviewer_source` values referenced below are resolved per § `reviewer_source` Lookup Order (later in this document) — read that section first if the resolution mechanism itself is in question; this rule only consumes the already-resolved value.

When a sustained finding's `reviewer_source` resolves to a real external identity (not the reserved `local` sentinel) and its `internal_match.match_status` is `novel`, emit the observer variant of the phase-containment block instead of the standard code-review block above — one block per finding, never both:

- `finding_key`: `post-review-observer:{stable_finding_key}` — this exact prefix is load-bearing (M26): `Get-EmissionGap` attributes a block to a surface by checking the `finding_key` prefix, so a block emitted with the wrong prefix is invisible to, or miscounted by, the reconciliation sweep even though it would pass schema validation.
- `caught_stage: post-review-observer`
- `escape_distance`: recomputed as `4 - ordinal(catchable_phase)` (post-review-observer projection = 4; same phase ordinals as above)
- `introduced_phase`, `catchable_phase`, `severity`, `systemic_fix_type`, `category`, `apparatus_meta`: same setter rule and carry-forward as the code-review block above

A fully literal canonical example, for a sustained post-review-observer finding on PR 879 — same paired shape as the code-review block above, distinguished by the `post-review-observer:` `finding_key` prefix, `caught_stage`, and its own `escape_distance` projection:

```markdown
<!-- phase-containment-879 -->
finding_key: post-review-observer:gh-5678
introduced_phase: implementation
catchable_phase: implementation
caught_stage: post-review-observer
escape_distance: 1
severity: medium
systemic_fix_type: skill
category: architecture
apparatus_meta: false
appended_at: 2026-07-18T22:20:00Z
<!-- /phase-containment-879 -->
```

**Novel-gating is a trinary, not a two-way rule (M25)**:

- `reviewer_source` is the reserved `local` sentinel → standard `code-review` block, unchanged.
- `reviewer_source` is a resolved real external identity AND `internal_match.match_status: novel` → observer block, which REPLACES the standard block. One defect, one block, never both.
- `internal_match.match_status` is `duplicate` or `ambiguous`, OR `reviewer_source` is the `unresolved` lookup-failure sentinel → NEITHER block is emitted.

Writing the unqualified two-way version of this rule — "any resolved external identity gets an observer block" — is wrong: it would emit an observer block for a `duplicate`-matched finding, double-counting one defect as both a catch-side overlap and an escape-side miss.

**Dispatch is exact-equality only (M40)**: test `reviewer_source -eq 'local'`, never `-like`, `-match`, or other containment-style matching. A real GitHub login literally named `local` is normalized to `ext-local` by the intake process specifically so it can be told apart from the reserved `local` sentinel (see `skills/code-review-intake/SKILL.md` § GitHub Review Mode, around line 21, for the normalization rule) — a containment-style dispatch would misclassify `ext-local` as pipeline-native and silently delete a real escape.

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

This section splits two previously-conflated rules — marker emission and the maintainer-interaction gate — so the always-emit behavior below does not read as contradicting the sustained-only scoping that follows it.

**Marker emission** (persisting `<!-- review-dispositions-{PR} -->` and `<!-- engagement-record-review-{PR} -->`) fires on **every** judge pass, including a zero-sustained pass:

- After the `<!-- review-judge-produced-{PR} -->` sentinel is confirmed written
- Even when no finding was judge-sustained this pass — per the M9 coverage semantics above (§ Scope, around line 277: "coverage means measurement, not presence"), a zero-sustained pass still emits both markers, with `entries: []` on the dispositions marker

**Disposition gate** (the `AskUserQuestion` / maintainer-interaction step, classification into routine vs load-bearing) fires only when there are findings to disposition:

- Over the judge-sustained findings from the `<!-- judge-rulings ... -->` block
- Only for sustained findings (`judge_ruling: sustained`); defense-sustained findings (`judge_ruling: defense-sustained`) are skipped silently (not disposition-gated)
- When there are zero judge-sustained findings, no finding enters classification and `AskUserQuestion` never fires this pass — but marker emission (above) still runs

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
2. **file:line:hash** — normalize the finding title (lowercase, remove punctuation, replace spaces with hyphens), then form `{relative_file}:{line}:{normalized-title-hash[:8]}` where hash is the first 8 hex chars of SHA-256 over the UTF-8 normalized title.
3. **finding_id fallback** — if neither is available, use the sequential `finding_id` (e.g. `F1`) with a `warn:` prefix to signal instability: `warn:F1`.

The `stable_finding_key` is what the resume-read mechanism uses to detect prior dispositions across re-reviews of the same PR (see § Stable-Key Resume below).

### `reviewer_source` Lookup Order (GitHub-Sourced Findings Only)

This lookup order applies only to findings that originated from an external GitHub review comment. Pipeline-native findings (local prosecution/defense/judge findings) never enter this lookup procedure — the disposition-recording sites below write `reviewer_source: local` directly for those findings, without evaluating any of the three tiers.

Both disposition-recording sites below (§ Routine Findings and § Load-Bearing Findings) write a `reviewer_source` field. For GitHub-sourced findings, resolve its value in this order:

1. **In-context intake ledger** — when the session is continuous with the GitHub-intake pass that built the finding, read the `reviewer_source` value the intake skill (`skills/code-review-intake/SKILL.md`) already recorded for this finding.
2. **`gh api` re-derivation** — otherwise (standalone or resumed judge pass), extract the `comment_id` embedded in the finding's `stable_finding_key` and re-derive the reviewer identity via `gh api`, trying the PR-review-comment, issue-comment, and review endpoints in turn. Parse rule: the `comment_id` is the numeric run immediately after the `gh-` prefix, up to the next `-` or end of string; this covers both the single-finding `gh-{comment_id}` key shape and the multi-finding `gh-{comment_id}-{hash}` key shape identically. Normalize the re-derived login per the canonical `reviewer_source` normalization rule in `skills/code-review-intake/SKILL.md` § GitHub Review Mode (lowercase, `.login`-only, trailing `[bot]` strip, quoted-scalar output, reserved-value/`ext-`-prefix collision escape) — this site does not restate that mechanism.
3. **`unresolved` sentinel** — on any failure (comment deleted, API error, no comment ID embedded in the key to re-derive from), write the sentinel `unresolved`. Never write `local` on lookup failure — `local` is reserved exclusively for pipeline-native (non-GitHub-sourced) findings, which are written directly per the guard above and never fall through to this sentinel.

### `internal_match` Writer Rule (GitHub-Sourced Findings Only, DD2)

`internal_match.match_status` and the PR-level `external_sources_reconciled` field are **written by the judge**, not merely consumed — § Observer emission variant (above) only ever reads the already-resolved value; this section is the writer contract those readers depend on.

At reconciliation time — with **both** the internal prosecution ledger (this PR's own pipeline-native findings) and the external review's findings in context simultaneously, per design decision DD2 — the judge sets `internal_match.match_status` on **every** external-source disposition entry (any entry whose `reviewer_source` resolved to a value other than `local`):

- **`duplicate`** — the external finding describes the same defect as an already-caught internal finding. Also write `matched_finding_key` with that internal finding's `stable_finding_key`.
- **`novel`** — the external finding has no matching internal finding; the pipeline missed it. This is what the observer emission variant later turns into a `post-review-observer` escape block.
- **`ambiguous`** — the judge cannot confidently resolve a match either way after verification. Excluded from `n₂`/`m`/coverage math downstream (Seam Specification) — an honest "could not resolve" must never be forced into `duplicate` or `novel`.

`reviewer_source: local` entries (pipeline-native findings) never carry `internal_match` — the field only applies to external-source entries. Field order matters: `internal_match` is written **before** `disposition_rationale` (M42) so a `disposition_rationale` block-scalar's free text can never be mistaken for the real field by a downstream line-regex parser.

**Scope (post-fix batch 4, issue #854 s6; corrected G-CR8, PR #859 GitHub-review post-fix): only when this pass ran in GitHub Review Mode.** The PR-level `external_sources_reconciled` field records that an external review was actually reconciled against — it is meaningless, and actively misleading, on a pass that never had one. Emit it once in the same posted marker **only when this pass is GitHub Review Mode** — determined from the session context/command that invoked this pass (`skills/code-review-intake/SKILL.md` § GitHub Review Mode (Proxy Prosecution Pipeline) — the `/review-github` proxy-prosecution path that ingests GitHub-sourced findings), never from entry presence. Within a GitHub Review Mode pass, emit it **even when empty** (`external_sources_reconciled: []`): a genuinely zero-finding external review is a legal, required coverage record (M9 — "coverage means measurement, not presence"), and omitting the field on a GitHub Review Mode pass is indistinguishable downstream from "this PR was never measured at all." A zero-finding external review pass has zero entries by definition, so a detection test keyed on entry presence (e.g. "at least one entry this pass whose `reviewer_source` resolved to a value other than `local`") can never fire on exactly the case M9 requires the field to be emitted for — GitHub Review Mode is a property of the SESSION, not a derived property of what got written. On a purely internal-only pass — plain `/orchestra:review`, no GitHub-sourced findings ingested this pass — **omit the field entirely**. Do not emit `external_sources_reconciled: []` on an internal-only pass: that would falsely claim an external review was reconciled and never occurred, manufacturing a measured-looking zero that was never actually measured (the exact false-clean coverage vector this issue exists to eliminate).

### Routine Findings — Silent Recording

For routine findings, the agent records the disposition silently in the `review-dispositions-{PR}` accumulator without firing an `AskUserQuestion`. Use `schema_version: 4` (current emission format); write `severity`, `stage`, and `reviewer_source` (the reviewer identity or class that produced the finding — use `local` for pipeline-native prosecution/defense/judge findings; external identities are resolved per § `reviewer_source` Lookup Order above) for all entries, `internal_match` for external-source entries (§ `internal_match` Writer Rule above), and include `ac_cross_check` for any `dismiss` or `defer` entry with severity ≥ medium. Remember the PR-level `external_sources_reconciled` field once per posted marker (§ `internal_match` Writer Rule above; § Persistence — Ordering below shows the full marker shape):

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

Record as (v4 format — include `severity`, `stage`, `reviewer_source`, `internal_match` for external-source entries (§ `internal_match` Writer Rule above), and `ac_cross_check` for dismiss/defer entries with severity ≥ medium):

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

This example's `reviewer_source: local` means no `internal_match` is written (pipeline-native). For a load-bearing finding whose `reviewer_source` resolved to an external identity, add `internal_match: { match_status: ... }` before `disposition_rationale`, same shape as the routine external-source example above.

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

1. **`<!-- review-dispositions-{PR} -->`** — Post as a PR comment. Payload: `schema_version: 4`, `passes_run: [...]`, `entries: [...]` (all findings, routine and load-bearing, one entry per finding), plus the PR-level `external_sources_reconciled` field. v2 added per-entry `severity`, `ac_cross_check`, and `stage` fields; v3 added per-entry `reviewer_source` (the reviewer identity or class — `local` for pipeline-native findings; external identities resolve per § `reviewer_source` Lookup Order above); v4 adds per-entry `internal_match` and the PR-level `external_sources_reconciled` field (see § `internal_match` Writer Rule below). This is the atomic per-finding record.

   ````text
   <!-- review-dispositions-{PR} -->

   ```yaml
   schema_version: 4
   passes_run: [1, 2, 3, 4, 5]
   entries:
     - stable_finding_key: "..."
       pass: 1
       disposition: incorporate
       classification: routine
       severity: medium
       stage: code-review
       reviewer_source: local   # pipeline-native finding: no internal_match (see below)
       disposition_rationale: "..."
       ac_cross_check:
         file_arm: false
         term_arm: true
         result: matched-high
         ac_ref: "- the AC line that matched"
         source: issue
         routed: force-accept
     - stable_finding_key: "gh-123456789"
       pass: 1
       disposition: incorporate
       classification: routine
       severity: medium
       stage: code-review
       reviewer_source: jdoe    # external identity, resolved per § reviewer_source Lookup Order
       internal_match:          # written BEFORE disposition_rationale (M42 field order)
         match_status: novel    # duplicate | novel | ambiguous — see § internal_match Writer Rule
       disposition_rationale: "..."
   external_sources_reconciled: ["gh-123456789"]   # PR-level; emitted ONLY because this pass ran in GitHub Review Mode (a property of the SESSION/command, e.g. /review-github — never inferred from entry presence). [] is a legal, required zero-finding coverage record WITHIN a GitHub Review Mode pass, never an omission; on a purely internal-only pass (no external-source entries this pass) OMIT this field entirely instead.
   ```
   ````

   > **v3 per-entry requirements** (carried over unchanged from v2): For entries with `disposition: dismiss` or `disposition: defer` and `severity` ≥ medium, `ac_cross_check` is required. The `ac_cross_check` object records which arms ran (`file_arm`, `term_arm`), the result tier (`matched-high | matched-ambiguous | no-match`), the matched AC reference if any, the source, and the routing outcome. Legacy `schema_version: 1` entries are exempt from this check. `artifact_citation` covers non-AC inherited artifacts; `ac_cross_check.ac_ref` is the AC-specific channel.
   >
   > **v4 requirements** (additive on top of v3): every external-source entry (`reviewer_source` not `local`) carries `internal_match.match_status`, written per § `internal_match` Writer Rule below. The PR-level `external_sources_reconciled` field is emitted once per posted marker **only on a GitHub Review Mode pass** (§ `internal_match` Writer Rule above) — including as `external_sources_reconciled: []` when that external review found nothing to reconcile. An absent field means this pass never attempted external reconciliation (the normal, expected state for a plain internal-only `/orchestra:review` pass); an empty array means a GitHub Review Mode pass measured and found zero (M9). Never emit the field on an internal-only pass, even as `[]` — that would misrepresent an unmeasured pass as a measured one. `reviewer_source` stays required on every entry, same as v3.
   >
   > **`stage` field values**: The `stage` field records which pipeline stage produced this entry: `code-review` for the post-judge disposition gate, `ce` for CE Gate defect deferral. Both stages use the same `ac_cross_check` pre-condition at severity ≥ medium.
   >
   > **In-session schema audit (before posting)**: Before posting the `review-dispositions-{PR}` comment to the PR, run a warn-only schema check using `.github/scripts/lib/review-dispositions-validator-core.ps1 -PullRequestNumber {PR} -InMemoryMarkers @($rawMarkerText)`. Surface any `findings` as warnings. This catches v4 schema violations (e.g., missing `ac_cross_check` on dismiss/defer entries at severity ≥ medium, or a missing `reviewer_source`) before the marker is committed to the PR timeline. The validator is warn-only and never blocks posting.

2. **`<!-- engagement-record-review-{PR} -->`** — Post as a separate PR comment (not the same comment as review-dispositions). Payload follows `skills/engagement-record-emission/SKILL.md` shape at `schema_version: 4`, `phase: review`. Load-bearing findings that fired `AskUserQuestion` appear in `load_bearing_decisions[]` with their `engineer_choice` and `audit_rationale`. Routine findings do not appear in the engagement-record.

   The engagement-record carries the `same-decision-resume` identity; the review-dispositions carries the per-finding outcome record. Never merge the two into a single comment.

### SMC References

- **SMC-19** — `finding_dispositions` is design-only (issue-keyed on `design-phase-complete`). This section's `review-dispositions` is a distinct, PR-keyed path.
- **SMC-23** — governs `review-dispositions-{PR}` + `engagement-record-review-{PR}` survival, write path (PR comments), and cross-tool fungibility.
- **SMC-20** — extended to include `review` phase; governs `engagement-record-review-{PR}` cross-session resume semantics.

### Gotcha: Gate fires post-judge, not inside judge

The classification gate fires in the **owning parent workflow** after receiving the judge output. The judge body (this skill's judgment pass) ends at the judge-rulings comment. Do not add gate logic inside the judge's verification or scoring steps — doing so would conflate two distinct phases and make re-running the judge independent of dispositions impossible.
