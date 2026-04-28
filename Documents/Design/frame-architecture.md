# Design: Frame Architecture for Pipeline Enforcement

> **Status**: Living V2 design — revised after walking the model against four historical PRs (#411, #415 post-thin/fat; #286, #338 pre-thin/fat). Audit findings remain the target architecture; current shipped behavior now includes the first frame validator slice.
>
> **Author context**: Originally drafted in the Experience-Owner role during exploratory framing. Subsequent sub-issue work updates current-state sections as behavior ships.

---

## Summary

Agent Orchestra delivers customer-visible work through a pipeline of phases (experience framing, design, plan, implement, review, CE Gate, post-PR). Today, whether each phase actually fires on a given PR depends on **agent prose interpretation** of conductor rules — and since the thin-agents/fat-skills split, prose-only enforcement has drifted: phases get skipped silently and the operator can only detect the gap by manual audit after the fact.

This design introduces a **frame** — a hexagonal-architecture-style contract that declares the required phases as **ports**, allows multiple **adapters** (skills/sub-skills) to fill each port, captures completion as **credits** in a structured PR ledger, and **enforces** completion via a pre-PR hook that blocks PR creation if any port lacks a credit. The frame separates **what must happen** (deterministic, declared in port files) from **how it happens this time** (judgment, contextual selection of an adapter), removing the prose-trust spine while preserving agent flexibility.

The first deliverable is **audit-only**: build the credit ledger format, back-derive credits from existing markers across recent PRs, and report the actual gap rate per port. Enforcement comes after the audit shapes priorities.

---

## Customer Framing

### Who the customer is

Two journeys, both currently degraded:

- **Operator** — the human running `/orchestrate`, `/plan`, `/design`, `/experience`, `/orchestra:review`, etc. Wants confidence that "all the rigor I designed in" actually happens for each PR.
- **Maintainer** — the human adding a new skill or capability. Wants to declare a new adapter and have it discoverable by the frame without hand-editing conductor prose.

### Problem statement

> *"I launch a flow expecting end-to-end rigor. Mid-flow or post-PR I realize step X never fired. There is no way, before merging, to tell whether a PR ran the full pipeline. Every PR becomes a manual audit."*

Since the thin-agent / fat-skill split, the spine that says **"for this kind of change, these things must happen"** got distributed across prose and stopped being load-bearing. Skills are smaller and more reusable, but enforcement evaporated.

### Customer journeys

| Journey | Today | Target |
|---|---|---|
| Launch flow on a feature issue | Conductor narrates phases; some quietly don't fire | Frame manifest declares 13 ports; each port either gets a real credit, an auto-not-applicable credit, or an explicit-skip credit with justification |
| Add a new specialist skill | Edit Code-Conductor prose, hope the right judgment branch fires | Skill declares `provides: <port>` in frontmatter; frame validator confirms port-adapter consistency on startup; conductor prose untouched |
| Audit a past PR for completeness | Read every conductor narration; reconstruct from issue markers | Read one credit-ledger comment on the PR; every port has an entry with status, adapter, evidence link |
| Stop a flow mid-review | Orphan ledgers exist but PR is shippable | Orphan ledgers exist; gate blocks PR until terminal credit (judge ruling) is written |

### Design intent (in customer terms)

- **No silent gaps.** Every port in the frame appears in every PR's credit ledger — passed, failed, skipped, or not-applicable. The operator can never wonder "did X run?" because the absence of a credit is itself impossible.
- **Justification is first-class.** Skipping a port requires a reason that travels with the PR and is challengeable in review.
- **Selection is judgment, enforcement is mechanical.** The agent picks which adapter is right for the change. The hook only checks that some adapter produced a credit. Trust the agent to choose; don't trust prose to remember.
- **The frame is additive.** Existing markers, existing skills, existing agents continue to work. The frame discovers and aggregates rather than rewriting.

### CE Gate readiness

This is meta-infrastructure (work about how work happens). Direct CE Gate exercise is limited:

- **Functional surface**: the credit ledger comment on a real PR — does it parse, does it render, does it block correctly?
- **Intent surface**: does an operator looking at a blocked PR understand what's missing and how to recover?
- **Negative surface**: does the gate fail-open or fail-closed under malformed ledgers, missing port files, hook errors?

Detailed CE scenarios are deferred until the audit-only sub-issue produces a concrete ledger format to exercise.

---

## Vocabulary

| Term | Definition |
|---|---|
| **Frame** | The contract — "what a complete change looks like." Encoded as a directory of port files. |
| **Port** | A required slot in the frame, corresponding to a question a customer would ask about a PR (e.g., "was this reviewed?"). |
| **Adapter** | A skill, sub-skill, or agent step that can fill a port (e.g., `review-standard`, `review-lite`). |
| **Selector** | The agent's judgment about which adapter to plug in for this change, based on adapter `applies-when` predicates. |
| **Credit** | Persisted, machine-readable evidence that a port was filled (or skipped with justification). One credit per port per PR. |
| **Credit ledger** | A single structured PR comment listing every port's credit. The pre-PR hook reads this. |
| **Gate** | The pre-PR hook that blocks PR creation if any port in the frame lacks a credit. |
| **Auto-N/A adapter** | A special adapter per port that fires when a declarative predicate matches "this PR has nothing for this port to do," writing a `not-applicable` credit. |
| **Explicit-skip adapter** | A special adapter per port that requires an operator/agent to supply a justification. Writes a `skipped` credit. The escape hatch for cases predicates don't capture. |
| **Terminal-step rule** | The credit for a multi-stage adapter is written by the *terminal* step (the one that produces the customer-relevant outcome), not by intermediate steps. |
| **Trigger-conditional port** | A port that only applies when a triggering signal occurs in another port's output (e.g., `post-fix-review` fires only when `review` finds a Critical/High; `process-review` fires only when CE Gate finds a defect). Distinct from always-applies. |
| **Inconclusive credit** | A credit-status value distinct from `skipped` and `not-applicable`. Used when an adapter could not complete because of an environmental constraint (e.g., browser tools unavailable, runtime surface unreachable). Recoverable; gate may treat as soft-block depending on port configuration. |

### Port-naming principle

A port corresponds to **a question a customer would ask about a PR**. Stages internal to an adapter (e.g., review's prosecute → defend → judge) are *not* separate ports because they don't answer separate customer questions — the judge ruling *is the answer* to "was this reviewed?".

This is the test for whether to split or merge a port.

---

## Canonical Port List (V2)

**Seventeen ports**: 14 always-applies + 3 trigger-conditional. Flat list — sub-ports rejected during design (parent nodes added bookkeeping without structural meaning). Display can group by name prefix without altering the gate's data model.

### Always-applies ports (14)

| Port | Adapter family today | Auto-N/A rule (declarative) |
|---|---|---|
| `experience` | Experience-Owner upstream framing | `changeset.complexity == trivial` |
| `design` | Solution-Designer 3-pass exploration | `changeset.complexity == trivial` |
| `plan` | Issue-Planner | `changeset.complexity == trivial` |
| `implement-code` | Code-Smith | no source files changed |
| `implement-test` | Test-Writer | no testable code changed |
| `implement-refactor` | Refactor-Specialist | no touched-area debt above threshold |
| `implement-docs` | Doc-Keeper | no behavior or interface in docs changed |
| `review` | Code-Critic + Code-Review-Response (variants: standard, lite, judge-only, proxy-github) | (always applies) |
| `ce-gate-cli` | CLI-surface scenario exercise | CLI surface not touched |
| `ce-gate-browser` | Browser-surface scenario exercise | web UI not touched |
| `ce-gate-canvas` | Canvas-surface scenario exercise | canvas surface not touched |
| `ce-gate-api` | API-surface scenario exercise | API surface not touched |
| `release-hygiene` | plugin-release-hygiene + version-bump check | no plugin entry-point or manifest files changed |
| `post-pr` | post-pr-review checklist | (always applies) |

### Trigger-conditional ports (3)

These ports do not have a predicate-based applies-when. They activate when a triggering signal appears in another port's credit. If the trigger does not fire, the port is auto-N/A with the trigger absence as evidence.

| Port | Trigger | Adapter family today |
|---|---|---|
| `post-fix-review` | `review` credit contains a sustained Critical or High finding | Code-Critic post-fix prosecution |
| `process-review` | CE Gate credit shows a sustained defect (`ce_gate_defects_found > 0`) | Process-Review |
| `process-retrospective` | (TBD — currently undecided whether always-applies, post-pr-conditional, or formally retired) | Step 11 retrospective practice (visible in #286 only) |

### Revisions from V1 → V2 (driven by audit)

- Dropped `scope.isHotfix` from `experience`/`design`/`plan` auto-N/A predicates. Audit showed PR #415 (a bug fix) ran all three. Trivial-complexity is the only reliable predicate.
- Added `release-hygiene` port. Every recent merged PR shows version bumps across 4-5 manifest files with no enforcement.
- Added `post-fix-review` port. PR #286 ran it explicitly; today it lives inside `review`'s prose. It has a distinct trigger and scope, so it deserves its own credit.
- Added `process-review` and `process-retrospective` as trigger-conditional ports.
- `process-retrospective` flagged as TBD — visible in pre-thin/fat #286 but absent in all three other PRs. Decision in audit-only sub-issue: lift to first-class port, fold into `post-pr`, or retire the practice.

Notes (unchanged from V1):

- Every port **always applies** to every PR — except trigger-conditional ports, whose applicability is itself derived from another port's credit (not silently skipped: an explicit "trigger absent" credit is still written).
- For ports with multiple work-adapter variants (today: `review`, `experience`), the SKILL.md acts as the adapter directory.

Notes:

- Every port **always applies** to every PR. Variation lives in adapter selection, including the auto-N/A adapter. There is no port-level "this port doesn't apply" silent skip.
- For ports with multiple work-adapter variants (today, only `review`), the SKILL.md acts as the adapter directory:

  ```text
  skills/adversarial-review/
    SKILL.md            # describes the port + lists adapters
    adapters/
      standard.md       # provides: review, applies-when: changeset.totalLines >= 200
      lite.md           # provides: review, applies-when: changeset.totalLines < 200
      judge-only.md     # provides: review, applies-when: scope.isReReview
  ```

- For single-adapter ports the directory is degenerate (one entry). The model accommodates both.

---

## Adapter Model

### Adapter declaration

Adapters declare port intent in their frontmatter (skill, agent, or command):

```yaml
---
name: code-critic-lite
provides: review
applies-when: changeset.totalLines < 200
produces-credit: review.{adapter}.{timestamp}
---
```

The current frame validator ships as `.github/scripts/frame-validate.ps1`, backed by `.github/scripts/lib/frame-validate-core.ps1` and `.github/scripts/lib/frame-predicate-core.ps1`. `quick-validate.ps1` aggregates it as `FrameValidator`, so the validator passes or fails with the existing structural validation suite rather than adding a separate CI lane.

The first shipped validator slice is intentionally symmetry-only plus predicate parse-only:

- Port names come from `frame/ports/*.yaml` filename stems. The YAML body is opaque to the validator.
- Adapter discovery scans `agents/*.agent.md`, `agents/*.md` excluding `.agent.md`, `commands/*.md`, `skills/*/SKILL.md`, and direct `skills/*/adapters/*.md` files.
- Every discovered adapter `provides:` value must match a `frame/ports/*.yaml` stem. A port with no adapter declaration is allowed in this slice; coverage strictness waits until adapter declarations and enforcement semantics are in place.
- If `frame/ports/` is missing, adapter symmetry passes with informational detail and predicate parsing still runs.
- Frontmatter handling is deliberately lightweight. It accepts the scalar, inline-list, indented-list, comment, and block-scalar forms used by adapter declarations, but it is not a full YAML parser.

### Three adapter types per port

| Type | Count per port | Purpose |
|---|---|---|
| **Work adapter** | ≥1 | Does the actual thing. Has positive `applies-when`. |
| **Auto-N/A adapter** | 0 or 1 | Fires when declarative rule matches "nothing to do." Writes `not-applicable` credit with the matched rule as evidence. No judgment. |
| **Explicit-skip adapter** | exactly 1 | Operator/agent invokes with `reason`. Writes `skipped` credit. Justification is visible in PR review and challengeable. |

### Selection (where judgment lives)

Each agent that owns a port is responsible for selection. When the agent runs:

1. Read the port file for its port.
2. Evaluate each adapter's `applies-when` against the changeset.
3. Pick the matching adapter (port file declares precedence if multiple match: `default: review-standard`).
4. If no adapter matches, invoke the explicit-skip adapter with a justification.

The pre-PR hook independently verifies via the credit. Selection logic is never re-run by the hook — it just checks that *some* credit exists.

### `applies-when` predicate language

Target enforcement evaluates the declarative DSL against:

- `git diff` against the merge target (file list, line counts, paths)
- Repo signals (file patterns, surface markers)
- Operator-supplied scope label (only for explicit-skip; `applies-when` predicates do not read scope class to prevent gaming)

Examples:

```yaml
applies-when: changeset.touches('src/ui/**')
applies-when: changeset.totalLines < 200
applies-when: not changeset.touchesSource()
applies-when: changeset.touches('docs/**') and changeset.behaviorChanged()
```

The grammar is small and deterministic. Current validation is parse-only: it accepts comparisons, logical `AND`/`OR`/`NOT`, grouped expressions, dotted identifiers, bare boolean identifiers such as `scope.isReReview`, and function-call predicates with literal arguments such as `changeset.touches('docs/**')`. It rejects malformed syntax but does not validate field existence, function existence, or type consistency; those semantic checks are deferred to the evaluator work. The target hook evaluates valid predicates; the agent does not.

---

## Credit Ledger Schema (evolves existing pipeline-metrics)

The audit revealed that the **`<!-- pipeline-metrics ... -->` YAML block already embedded in every recent PR body IS the de facto credit ledger.** It is in production at `metrics_version: 2`, written by Code-Conductor on PR creation, and machine-parseable today. The frame ledger is `metrics_version: 3` — a backwards-compatible extension that adds port-level structure on top of the existing finding-level fields.

The previously documented marker `<!-- code-review-complete-{PR} -->` is design-on-paper — it does **not** appear on real PRs. Do not anchor enforcement on it. Anchor on the pipeline-metrics block in the PR body.

Per-agent issue markers (`<!-- experience-owner-complete-{ID} -->`, `<!-- design-phase-complete-{ID} -->`, `<!-- plan-issue-{ID} -->`) **do** appear reliably on linked issues and remain valuable as **evidence pointers** referenced by credit entries. They are not replaced.

```yaml
# Embedded in PR body as an HTML comment
<!-- pipeline-metrics
metrics_version: 3
frame_version: 1.0
pr: 123
generated_at: 2026-04-24T14:30:00Z

# NEW in v3: per-port credits (preserves all v2 finding-level fields below)
credits:
  - port: experience
    adapter: experience-owner-upstream
    status: passed                          # passed | failed | skipped | not-applicable | inconclusive
    evidence: gh-issue-comment://issue/456#issuecomment-789
    applied-by: Experience-Owner
    selector-reason: "complexity > trivial"
    timestamp: 2026-04-24T14:00:00Z

  - port: design
    adapter: design-auto-na
    status: not-applicable
    rule: "changeset.complexity == trivial"
    evidence: changeset:diff-stat@HEAD
    applied-by: Code-Conductor
    timestamp: 2026-04-24T14:02:00Z

  - port: ce-gate-browser
    adapter: exercise-browser-scenarios
    status: inconclusive
    reason: "browser tools unavailable in this environment; runtime scenarios not exercised"
    applied-by: Experience-Owner
    timestamp: 2026-04-24T14:20:00Z

  - port: review
    adapter: review-standard
    status: passed
    evidence: pipeline-metrics#findings           # internal pointer to v2 fields below
    applied-by: Code-Review-Response
    selector-reason: "changeset 1735/-785, full prosecution depth"
    judge-score: 5-accepted/1-rejected/0-deferred
    integrity-check:
      expected-pass-blocks: [1, 2, 3]
      observed-pass-blocks: [1, 2, 3]
      passed: true
    timestamp: 2026-04-24T14:25:00Z

  - port: post-fix-review
    adapter: post-fix-review-trigger-absent
    status: not-applicable
    rule: "no Critical or High finding sustained in review credit"
    timestamp: 2026-04-24T14:26:00Z

  - port: release-hygiene
    adapter: plugin-release-hygiene
    status: passed
    evidence: changeset:plugin.json,marketplace.json,README.md
    applied-by: Code-Conductor
    version-bump: 2.3.0 -> 2.3.1
    timestamp: 2026-04-24T14:28:00Z

  - port: implement-refactor
    adapter: implement-refactor-explicit-skip
    status: skipped
    reason: "Touched files have outstanding refactor PR #119; avoid conflicting cleanup."
    applied-by: Code-Conductor
    timestamp: 2026-04-24T14:18:00Z

  # ... 17 entries total (14 always-applies + 3 trigger-conditional)

# v2 fields preserved unchanged below — readers of v2 see the legacy block; v3-aware readers consume credits[]
prosecution_findings: 6
defense_disproved: 1
judge_accepted: 5
judge_rejected: 1
judge_deferred: 0
ce_gate_result: passed
ce_gate_intent: partial
ce_gate_defects_found: 0
rework_cycles: 1
postfix_triggered: false
findings: [ ... per-finding ledger as today ... ]
-->
```

### Credit-author rule

**The adapter writes its own credit on completion.** No central writer. This matches today's marker pattern and the existing pipeline-metrics writer in Code-Conductor.

For the v2 → v3 migration: Code-Conductor's existing pipeline-metrics emitter is extended to write the `credits:` array alongside the v2 fields. Per-port adapters provide their credit entry via a small helper protocol; Conductor concatenates them into the final block. v2-only consumers continue to read the legacy fields without breaking.

### Terminal-step rule (closes partial-completion gap)

For multi-stage adapters, **only the terminal step writes the credit.**

Concrete examples:

- `review` credit is written by the **judge** (Code-Review-Response) after consuming both prosecution and defense ledgers. Prosecution and defense produce inputs only — neither writes a credit.
- `implement-test` credit is written when tests are committed and pass, not when Test-Writer is dispatched.
- `ce-gate-{surface}` credit is written when the evidence summary is captured, not when the surface run starts.
- `implement-docs` credit is written when the doc edit is committed, not when Doc-Keeper is invoked.

**Consequence**: partial states (e.g., a prosecution ledger with no judge ruling) exist as recoverable orphans but cannot satisfy the port. The gate stays closed until the terminal step completes. Recovery is well-lit (`/orchestra:review-judge` consumes existing ledgers).

### Input-integrity rule

Terminal-step adapters verify their inputs are complete before writing the credit. Example: judge verifies the prosecution ledger contains all expected pass-block IDs (`pass: 1`, `pass: 2`, `pass: 3` for standard) before writing a `passed` credit. If a pass block is missing, judge writes a `failed` credit (or refuses to write) with the gap as evidence.

This closes the only failure mode the terminal-step rule alone doesn't address: an adapter that internally short-circuits its sub-stages.

**Audit confirmation**: PR #411's pipeline-metrics block contains an explicit warning that "*pass-level distribution was not durably persisted in-session*" with `pass_1/2/3_findings: n/a`. Today this ships unchallenged. The integrity-check rule would have flagged it (observed-pass-blocks: empty; expected: [1,2,3] for standard) and the judge would have written `failed` instead of `passed`.

**Express-lane carve-out**: PR #338 used `express_lane` to fast-path 5 of 12 findings past full defense. The integrity check must accept express-lane findings as valid — the rule is "every expected pass block has *some* terminating outcome (full ruling OR express-lane ruling)," not "every finding has full defense." The `express_lane: true` field on a finding entry counts as the terminator.

---

## Pre-PR Hook Contract

```text
on `gh pr create` (or push to PR branch with auto-PR):

  1. Read frame/ports/*.yaml                  # canonical port list
  2. Find the PR's frame-credit-ledger comment
     (if missing → BLOCK with "no credit ledger present; run frame init")
  3. For each port in frame:
       evaluate applies-when of each adapter against the live changeset
       look up the credit entry for this port in the ledger:
         - missing entry            → BLOCK with "missing credit: <port>"
         - status: failed           → BLOCK with "<port> failed, see <evidence>"
         - status: passed           → OK
         - status: skipped          → OK (justification visible in PR review)
         - status: not-applicable   → OK (rule cited in entry)
  4. All ports satisfied → allow PR creation
```

The hook never reads agent prose. It reads ports + ledger. The hook is the only enforcement layer (declined dual-layer-with-self-check during design — pre-PR hook only).

### Failure-message contract

Every BLOCK message names:

- The missing/failed port
- What adapter would have filled it (so the operator knows what to run)
- The recovery command (e.g., `/orchestra:review-judge`)

Operators should never see a generic "frame check failed" — always actionable.

---

## Audit-Only Kickoff (Sub-Issue #1)

Cheapest path to evidence: extend the existing pipeline-metrics block to v3 with a `credits[]` array, back-derive credit arrays from existing markers + PR-body sections across recent PRs, report the gap rate per port. **No enforcement yet.**

### Deliverables

1. **`frame/ports/*.yaml`** — the 17 port files (14 always-applies + 3 trigger-conditional), declarative.
2. **`frame/pipeline-metrics-v3-schema.yaml`** — schema doc that extends `metrics_version: 2` with the `credits[]` array, status enum (`passed | failed | skipped | not-applicable | inconclusive`), and integrity-check fields. Backwards-compatible with v2 readers.
3. **`scripts/frame-back-derive.ps1`** — script that, given a PR number:
   - Reads PR body (existing v2 pipeline-metrics block), diff, linked issue markers, PR-body sections (Adversarial Review Scores, CE Gate, Validation Evidence, Process Gaps)
   - Constructs a synthetic v3 credit array using the back-derivation rules below (era-aware)
   - Optionally posts the synthesized v3 block as a draft comment for inspection
4. **`scripts/frame-audit-report.ps1`** — runs back-derivation across the last N merged PRs, emits a report:
   - Per-port: how often `passed`, `not-applicable`, `skipped`, `inconclusive`, **missing**
   - Per-PR: which ports were missing
   - Top-N most-frequently-missing ports → drives sub-issue priority
   - Era split: pre-thin/fat (before PR #356, 2026-04-17) vs post-thin/fat — to test the hypothesis that drift increased after the split

### Back-derivation rules (era-aware)

| Signal | Implies | Era |
|---|---|---|
| `<!-- experience-owner-complete-{ID} -->` on linked issue | `experience: passed` | both |
| `<!-- design-phase-complete-{ID} -->` on linked issue | `design: passed` | both |
| `<!-- plan-issue-{ID} -->` on linked issue | `plan: passed` | post-thin/fat only |
| Linked issue body has "Implementation Plan" / "Acceptance Criteria" section but no `plan-issue-{ID}` marker | `plan: passed` (era-fallback) | pre-thin/fat |
| PR body contains `## Adversarial Review Scores` table with judge-rulings count > 0 | `review: passed` (with score) | both — primary signal |
| PR body contains `<!-- pipeline-metrics ... -->` v2 block with `judge_accepted/rejected/deferred` populated | `review: passed` integrity-check pass | both |
| Same block has `pass_1/2/3_findings: n/a` with reconstruction warning | `review: passed` integrity-check **fail** — flag for review | post-thin/fat (#411 case) |
| PR body has `## CE Gate` with "passed", "skipped", or "not applicable" wording | `ce-gate-*` per surface (default to single ce-gate-cli credit until surface-tagging exists) | both |
| PR body CE Gate says "skipped" with environment reason | `ce-gate-*: inconclusive` (NOT skipped — distinguish per V2 status enum) | both |
| Diff touches `plugin.json`, `.claude-plugin/plugin.json`, `marketplace.json`, or version badge | `release-hygiene: passed` if version bumped, else `failed` | post-thin/fat (release-hygiene era) |
| `## Adversarial Review Scores` shows "Post-fix Review" row with prosecutor pts | `post-fix-review: passed` | both |
| PR body mentions "Process-Review: not triggered" or absent and `ce_gate_defects_found: 0` | `process-review: not-applicable` (trigger absent) | both |
| PR body contains `## Process Retrospective` section | `process-retrospective: passed` | currently observed only on #286 |
| PR body has `## Validation Evidence` with passed Pester/lint/structural checks | adapter input-integrity for `implement-test`/`implement-code` | both |
| Diff touches `docs/**` only | `implement-code/test/refactor: not-applicable`, `implement-docs: passed` | both |
| No signal found and no auto-N/A rule matches | **missing** (the gap) | both |

The audit's value is in the **missing** column — it tells us empirically which ports actually drift, and the era split tells us whether thin/fat made it worse.

### Audit's expected output (sample)

```text
=== Frame Audit Report (last 30 merged PRs) ===

Era split:
  pre-thin/fat (15 PRs):  missing-rate 11% across 14 ports
  post-thin/fat (15 PRs): missing-rate 19% across 17 ports

Most-missing ports (post-thin/fat):
  1. release-hygiene             missing in 5/15 PRs
  2. process-retrospective       missing in 14/15 PRs (likely retire)
  3. ce-gate-{surface}-specific  missing or surface-unspecified in 12/15 PRs
  4. review (integrity-check)    pass-distribution undurable in 4/15 PRs
  5. experience                  missing in 2/15 PRs

Recommended sub-issue priority:
  1. release-hygiene port + adapter (high frequency, easy enforcement)
  2. review integrity-check (closes the durability gap directly)
  3. CE Gate surface tagging (currently single-credit; needs per-surface)
  4. Decision: process-retrospective port or retire?
```

### Out of scope for the audit

- The pre-PR hook
- Adapter declarations in skill frontmatter
- Frame validator
- Any blocking behavior

These come in subsequent sub-issues, prioritized by audit findings.

---

## Sub-Issue Roadmap (Tentative)

Order is intentional but flexible — actual priority will shift based on audit-report missing-rate per port. Sub-issues 1–4 are foundational and should land in order; 5+ are port reifications driven by audit data.

| # | Sub-issue | Deliverable | Depends on |
|---|---|---|---|
| 1 | **Audit-only credit ledger from existing markers + pipeline-metrics v3 schema** | Schema doc, port files (17), back-deriver script, audit report. No enforcement. | — |
| 2 | Frame validator (lint/CI step) | Walks `frame/ports/*.yaml` and adapter frontmatter; fails CI when an adapter declares a non-existent port and when `applies-when` cannot parse. Missing adapters for existing ports are allowed until coverage enforcement ships. | #1 |
| 3 | Adapter declarations in skill/agent frontmatter | All current skills/agents declare `provides: <port>` and `applies-when` predicates. Validator (#2) passes. | #1, #2 |
| 4 | Pre-PR hook (warn-only mode) | Hook exists, reads PR body's pipeline-metrics v3 block, posts a comment listing missing/failed/inconclusive credits. **Does not block.** | #1, #3 |
| 5 | Reify `review` port end-to-end with input-integrity check | Code-Review-Response writes the v3 credit on judge completion; integrity check verifies pass-block durability (closes #411-style gap). | #4 |
| 6 | Reify `release-hygiene` port | plugin-release-hygiene skill declares `provides: release-hygiene`; predicate detects entry-point/manifest changes; auto-N/A path for non-release PRs. | #3 |
| 7 | Reify CE Gate surface ports + `inconclusive` status path | `ce-gate-cli/browser/canvas/api` adapters with surface-touch predicates; CE Gate emits `inconclusive` when environment unable to exercise (not silently `skipped`). | #3 |
| 8 | Reify `experience`, `design`, `plan` ports | Pipeline-entry agents emit credits with `applies-when` based on `changeset.complexity`. | #3 |
| 9 | Reify `implement-*` ports | Specialist agents emit credits; Validation Evidence table consumed as input-integrity inputs. | #3 |
| 10 | Reify `post-pr` and `post-fix-review` ports | Trigger-conditional logic for post-fix-review; explicit credit for post-pr cleanup. | #5 |
| 11 | Decision: `process-retrospective` port or retire | Audit shows usage rate; decide formalize-as-port or remove from practice. | #1 |
| 12 | Reify `process-review` port | Trigger-conditional on CE Gate defects. | #7 |
| 13 | Pre-PR hook switches to **blocking mode** | After all 17 ports have adapters and audit shows acceptable credit-rate, hook upgrades from warn → block. **The actual rails turn on.** | All preceding |

---

## Open Questions Resolved by Audit

| V1 question | V2 resolution |
|---|---|
| Does the 13-port set cover everything? | **No.** Audit added 4: `release-hygiene` (always-applies), `post-fix-review`, `process-review`, `process-retrospective` (all trigger-conditional or TBD). Total = 17 ports. |
| Is back-derivation accurate for both eras? | **Era-aware fallbacks required.** Pre-thin/fat PRs lack `plan-issue-{ID}` markers; the back-deriver infers from PR-body sections instead. Documented in the rules table. |
| How to distinguish "port wasn't required at the time" from "port was missed"? | Era split in audit report: pre-thin/fat reports against 14 ports, post-thin/fat against 17. Trigger-conditional ports auto-N/A under their trigger absence rule across both. |
| Does the flat list still feel right? | **Yes.** Walking 4 PRs, no decomposition pressure emerged. Display grouping (`implement-*`, `ce-gate-*`) is sufficient. |
| Where does selector logic live for ports without an agent owner (e.g., `post-pr`)? | Code-Conductor owns selection for ports whose adapter is a skill (not an agent). The selector reads the port file, evaluates `applies-when`, calls the skill or its auto-N/A adapter. Same pattern; just different invoker. |

## Open Questions Still Live (Resolve During Sub-Issue Work)

- The `<!-- code-review-complete-{PR} -->` marker is documented but absent from real PRs. Should we (a) retire the marker from documentation, (b) backfill it via a hook on PR creation, or (c) leave it as an alias for the v3 review credit? Decide in sub-issue #5.
- `process-retrospective` was visible in only 1 of 4 audited PRs. Decide in sub-issue #11 whether to formalize as a port, fold into `post-pr`, or retire the practice.
- CE Gate surface tagging is currently single-credit (one `ce-gate` block per PR, not per surface). Decide in sub-issue #7 whether to require surface-tagged credits or accept the single-credit shape with a `surfaces: [cli, browser]` field.
- For PRs that ran `review` in *both* main and proxy-GitHub modes (PR #415), do we emit one `review` credit or two? Decide in sub-issue #5 — probably one credit with a `mode: main+proxy` field, evidence linking both.

---

## Decision Log

| # | Decision | Choice | Rationale | Status |
|---|---|---|---|---|
| F1 | Enforcement gate location | Pre-PR hook only | Strongest rails; agent prose stops being load-bearing for completion checks. | V1 |
| F2 | Credit shape | **Evolve existing pipeline-metrics block to v3** (extend, don't replace) | Audit confirmed pipeline-metrics block already exists and is in production at v2. The `<!-- code-review-complete-{PR} -->` marker is design-on-paper and absent from real PRs. Anchor on what exists. | V1 → **V2 revised** |
| F3 | First cut scope | Audit-only across all ports as sub-issue #1 | Cheapest path to evidence; surfaces real gap rate before building enforcement. | V1 |
| F4 | Adapter declaration | Skill/agent frontmatter declares `provides`, central manifest is truth | Robustness + low ceremony; validator catches drift. | V1 |
| F5 | Port shape | Flat ports, no sub-ports | Sub-port grouping added bookkeeping without structural meaning. Display can prefix-cluster. Confirmed by audit — no decomposition pressure emerged across 4 PRs. | V1 |
| F6 | Credit author | Adapter writes its own credit on completion | Matches today's marker pattern; avoids new bottleneck. Conductor remains the aggregator (writes the v3 block) but each adapter contributes its credit entry. | V1 |
| F7 | `applies-when` evaluator | Declarative DSL evaluated by the hook | Auditable; agent can't fudge applicability. | V1 |
| F8 | Selector locus | In each agent's prose, reading its own port file. Code-Conductor owns selection for skill-only ports (no agent owner). | Lightweight; no new component; hook independently verifies via credit. | V1 (clarified V2) |
| F9 | Port granularity principle | One port per customer-meaningful question about the PR | Internal stages of an adapter (prosecute/defend/judge) aren't separate ports. | V1 |
| F10 | All-or-nothing semantics | Terminal-step credit + input-integrity check | Partial states recoverable but not credit-writable; gate enforces at terminal point. **Audit confirmed need**: PR #411 shipped with `pass_1/2/3_findings: n/a` and an explicit "not durably persisted" warning that today goes unchallenged. | V1 (audit-validated V2) |
| F11 | Port applicability | Every port always applies; auto-N/A is an adapter, not a port-level skip | One mechanism, not two; no silent gaps; uniform audit trail. | V1 |
| F12 | **Trigger-conditional ports** | Three ports (`post-fix-review`, `process-review`, `process-retrospective`) activate only when a triggering signal appears in another port's credit. Trigger-absent still emits an explicit credit. | Audit revealed `post-fix-review` (in #286) and `process-review` (mentioned in #286, #411) have distinct triggers and scopes; folding them into other ports loses the conditional structure. | **V2 new** |
| F13 | **Credit status enum** | `passed` \| `failed` \| `skipped` \| `not-applicable` \| `inconclusive` | Audit revealed CE Gate "skipped — environment couldn't exercise" is neither a true skip nor truly N/A. Add `inconclusive` for environment/tooling-blocked states. | **V2 new** |
| F14 | **Auto-N/A predicate refinement** | Drop `scope.isHotfix` from `experience`/`design`/`plan`; use only `changeset.complexity == trivial` | Audit showed PR #415 (a bug fix) ran all three with full marker chain. The hotfix predicate would have wrongly auto-N/A'd. | **V2 new** |
| F15 | **Release-hygiene as a port** | Add `release-hygiene` (always-applies, auto-N/A on no entry-point/manifest changes) | Every recent PR shows version bumps with no enforcement; visible drift surface. | **V2 new** |
| F16 | **Express-lane carve-out in integrity check** | Integrity check accepts `express_lane: true` findings as valid terminators | PR #338 used express_lane on 5/12 findings; full-defense-required rule would have falsely flagged. | **V2 new** |
| F17 | **Pipeline-metrics versioning** | v2 → v3 is additive (preserve all v2 fields, add `credits[]` + `frame_version`). v2-only readers continue to work. | Backwards-compat is mandatory; existing tooling consumes v2 metrics today. | **V2 new** |

---

## Audit Evidence (4-PR Walkthrough)

PRs walked: **#411** (Phase 3 Code-Conductor, post-thin/fat), **#415** (inline-dispatch fix, post-thin/fat), **#286** (Fix Effectiveness, pre-thin/fat), **#338** (validated step commits, pre-thin/fat). Inflection point: PR #356 (issue #344, merged 2026-04-17) extracted thin-agents/fat-skills.

### Per-PR credit derivation (back-derived against V2 17-port set)

#### PR #411 — Phase 3 Code-Conductor (post-thin/fat, +1735/-785, 34 files)

| Port | Status | Evidence |
|---|---|---|
| `experience` | ✅ passed | `<!-- experience-owner-complete-403 -->` on issue #403 |
| `design` | ✅ passed | `<!-- design-phase-complete-403 -->` |
| `plan` | ✅ passed | `<!-- plan-issue-403 -->` |
| `implement-code/test/refactor/docs` | ✅ all 4 passed | 32 source/skill files, 7 new Pester contracts (29/29), composite extractions, README+CLAUDE+design doc |
| `review` | ⚠️ passed-with-integrity-fail | Adversarial scores 21/5; pipeline-metrics v2 block present BUT `pass_1/2/3_findings: n/a` with explicit "not durably persisted" warning. Today ships unchallenged. |
| `ce-gate-{cli,browser,canvas,api}` | ⏭️ all 4 N/A | "no exercisable customer surface" (meta-CE ran on orchestration surface, but not in surface enum) |
| `release-hygiene` | ✅ passed | Version bump 2.3.x → 2.3.1 across 4 manifest files + README badge |
| `post-pr` | ✅ passed | Version + docs symmetric |
| `post-fix-review` | ⏭️ trigger-absent | No Critical/High |
| `process-review` | ⏭️ trigger-absent | "not triggered; no sustained CE defect" |
| `process-retrospective` | ❌ missing | No Step 11 section |

#### PR #415 — Inline-dispatch fix (post-thin/fat, +382/-8, 12 files)

| Port | Status | Evidence |
|---|---|---|
| `experience` / `design` / `plan` | ✅ all passed | All three markers present on issue #412 — **disproves V1's `scope.isHotfix` auto-N/A predicate** |
| `implement-code/test/docs` | ✅ passed | 12 files, new Pester contract, session-hooks.md updated |
| `implement-refactor` | ⏭️ N/A | Surgical fix |
| `review` | ✅ passed (dual-mode) | Main: 0/0/0 (zero findings) + **proxy-GitHub intake** by owner: 3 accepted / 8 rejected. Two review modes; pipeline-metrics didn't capture proxy. |
| `ce-gate-*` | ⚠️ **inconclusive** | "*CE Gate skipped — runtime cross-surface manual scenarios were not exercised in this environment*" — today silent skip; V2 distinguishes as `inconclusive` |
| `release-hygiene` | ✅ passed | 2.3.4 bump |
| `post-pr` | ✅ passed | |
| `post-fix-review` / `process-review` / `process-retrospective` | ⏭️ all trigger-absent | |

#### PR #286 — Fix Effectiveness (pre-thin/fat, +2367/-115, 3 files)

| Port | Status | Evidence |
|---|---|---|
| `experience` | ✅ passed | `<!-- experience-owner-complete-264 -->` |
| `design` | ✅ passed | `<!-- design-phase-complete-264 -->` |
| `plan` | ❓ inferred-passed | **No `plan-issue-264` marker** (era-mismatch); inferred from PR-body "Key design decisions" section. Triggers era-aware fallback rule. |
| `implement-code/test/docs` | ✅ passed | 1 src file, 34 new tests, design doc |
| `implement-refactor` | ⏭️ N/A | Greenfield |
| `review` | ✅ passed | 7 rulings, full pipeline-metrics with per-finding ledger (better than #411 — pre-thin/fat era persisted full pass distribution) |
| `ce-gate-*` | ✅ passed (single-credit, no surface tag) | S1–S4 scenarios passed, intent: strong |
| `release-hygiene` | ⏭️ N/A (era) | Pre-plugin-release |
| `post-fix-review` | ✅ passed | Triggered by MF1 Critical, 0 findings clean — first concrete `post-fix-review` credit observed |
| `process-review` | ⏭️ trigger-absent | "no systemic gap found" |
| `process-retrospective` | ✅ passed | Explicit Step 11 section with slowdowns + workflow-guardrail improvement (the only PR with this) |

#### PR #338 — Validated step commits (pre-thin/fat, +243/-6, 11 files)

| Port | Status | Evidence |
|---|---|---|
| `experience` | ❌ **MISSING** | No `<!-- experience-owner-complete-336 -->` on issue #336 — **first real gap caught by audit** |
| `design` | ✅ passed | `<!-- design-phase-complete-336 -->` |
| `plan` | ❓ inferred-passed | No marker (era); D12/D13 decisions in body |
| `implement-code/test/docs` | ✅ passed | 11 files, Pester 385/0, design doc + 3 example dirs |
| `implement-refactor` | ⏭️ N/A | New feature |
| `review` | ✅ passed | 7 rulings; `express_lane_count: 5` (5/12 findings shortcut) — **drives F16 carve-out** |
| `ce-gate-*` | ⏭️ N/A | "agent orchestration definition change with no independently exercisable customer surface" — clean justified N/A, exact V1 model |
| `release-hygiene` | ⏭️ N/A (era) | |
| `post-fix-review` / `process-review` / `process-retrospective` | ⏭️ all trigger-absent / missing | |

### Cross-PR aggregate (4-PR sample)

| Port | passed | N/A | inconclusive | missing |
|---|---|---|---|---|
| `experience` | 3 | 0 | 0 | **1** (PR #338) |
| `design` | 4 | 0 | 0 | 0 |
| `plan` | 2 | 0 | 0 | 2 (era-fallback inferred-passed) |
| `implement-code/test/docs` | 4 each | 0 | 0 | 0 |
| `implement-refactor` | 1 | 3 | 0 | 0 |
| `review` | 4 (1 with integrity-fail) | 0 | 0 | 0 |
| `ce-gate-*` (any) | 2 | 1 | **1** | 0 |
| `release-hygiene` | 2 | 2 (era) | 0 | 0 |
| `post-pr` | 4 | 0 | 0 | 0 (inferred) |
| `post-fix-review` | 1 | 3 | 0 | 0 |
| `process-review` | 0 | 4 | 0 | 0 |
| `process-retrospective` | 1 | 0 | 0 | **3** |

Sample is too small to draw rates from. The audit-only sub-issue runs against the last 30+ PRs to produce statistically-meaningful gap rates.
