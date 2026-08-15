---
name: plan-authoring
description: "Reusable implementation-plan authoring methodology. Use when running read-only discovery, drafting execution steps with CE Gate coverage, or preparing a plan for adversarial stress-testing and approval; also when writing acceptance criteria that name a consumer, a population, or a proof standard, when answering the vacuity question about a criteria set, when tagging a claim source-read or sample-inferred in an epistemic map, and when deciding where an instruction belongs so its executor actually reads it. DO NOT USE FOR: plan persistence, approval-policy enforcement, or direct implementation work (keep those in Issue-Planner.agent.md or use implementation-discipline)"
---

<!-- platform-assumptions: markdown skill guidance for VS Code custom agents in Agent Orchestra; assumes Issue-Planner retains no-edit boundaries, approval prompting, and session-memory persistence semantics. -->
<!-- markdownlint-disable-file MD041 MD003 -->

# Plan Authoring

Reusable methodology for turning researched scope into an executable implementation plan.

## When to Use

- When a task needs read-only discovery before planning begins
- When ambiguities must be narrowed into approval-ready choices
- When a plan needs execution modes, requirement contracts, review stages, and CE Gate coverage
- When the draft plan should be stress-tested before approval

## Composite References

- [references/criteria-exhibits.md](references/criteria-exhibits.md): the incident detail behind § Criteria Lenses — the measured numbers, named artifacts, and failure sequences each lens was extracted from

## Purpose

Reduce ambiguity before implementation starts. Discovery should produce evidence, alignment should resolve open decisions, and the draft plan should be specific enough that downstream agents can execute it without re-deriving the work.

## Plan Entry and Amendment Triggers

Provenance: absorbed from historical Code-Conductor sources for plan entry (`agents/Code-Conductor.agent.md@08c55e7bbf9ca2386a20fc6db2aaa931a626798d:107-110`) and plan amendment (`agents/Code-Conductor.agent.md@08c55e7bbf9ca2386a20fc6db2aaa931a626798d:130`) for issues #557 and #590.

When the requested scope is well-defined and the acceptance criteria are stable, produce a direct execution plan. Stable scope can go directly into planning because the plan author's work is to convert known goals, constraints, and verification needs into executable steps without reopening settled decisions.

When the requested scope is exploratory, stabilize the acceptance criteria and constraints before drafting execution steps. Ambiguous or exploratory work needs this stabilization because implementation plans should not force runtime agents to infer product boundaries, acceptance criteria, or constraint trade-offs during execution.

When an approved plan already exists but scope or acceptance criteria have changed, gone stale, or become ambiguous, route the work back through Issue-Planner for amendment before runtime execution. Drift and stale criteria must be reconciled before execution so downstream agents act on the current contract rather than adapting an obsolete one at runtime.

Quick checklist before plan entry or amendment:

- Well-defined scope + stable acceptance criteria -> draft a direct execution plan
- Exploratory scope -> stabilize acceptance criteria and constraints before drafting steps
- Changed, stale, or ambiguous approved plan -> call Issue-Planner for amendment before execution

After selecting the entry or amendment path, continue to `## Discovery Workflow` and gather the evidence needed to support that path.

## Discovery Workflow

### 1. Gather Read-Only Evidence

Search broadly before reading deeply. Review the issue body, related design documents, decisions, instructions, and nearby implementations. The discovery pass should identify blockers, ambiguities, affected files or areas, and whether the change touches a customer-facing surface.

### 2. Reuse Existing CE Gate Inputs

If Experience-Owner already documented customer surface identification, tool availability, and scenarios in the issue body, reuse them directly. If that data is absent, derive a minimal CE Gate readiness assessment inline from the feature description and repository context.

When BDD is enabled, prepare scenario IDs and `[auto]` or `[manual]` classification using the `bdd-scenarios` skill.

### 3. Keep the Research Subagent Bounded

When delegating discovery to a subagent, keep the brief read-only and scope it to:

- High-level search before file reading
- Design and decision document review
- CE Gate surface identification and exercise method selection
- Missing information, technical unknowns, and feasibility risks
- When the subagent discovers an artifact contradiction — a named path, function, or schema field in the design notes that does not match the live tree — report it as a finding. The parent Issue-Planner context applies the write-back correction; the subagent does not edit.

For fan-out orientation reads within the discovery brief, route them to an Explore-tier dispatch per `research-methodology` § Two-Layer Research Delegation. Grounding Pass verification work (`## Discovery Workflow` § 4 below) always stays in-parent — it is never routed to a Layer-1 dispatch, per that section's Never delegate the verifier note.

Do not let the discovery pass draft the full plan.

### 4. Grounding Pass

Invariant: **no plan step may name an ungrounded artifact**. This discipline runs at Discovery (for artifacts named in the research inventory) and at first-naming (for any artifact the planner introduces while drafting a step).

Ground: function signatures, schema file paths, agent body paths, command surfaces, and migration targets. For each named artifact, run one batched `Grep`/`Read` to verify its claimed shape (name, path, interface, count). Do not re-verify already-grounded artifacts.

Artifacts introduced while drafting a plan step must be grounded before the step is finalized. The same invariant applies mid-draft.

When the research subagent surfaces a contradiction between a design-note artifact claim and the live tree — mismatched names, paths, shapes, or counts — **correct the issue** body **before drafting** the plan. The parent Issue-Planner context performs the correction (consistent with Issue-Planner's existing issue-body writes at `agents/Issue-Planner.agent.md:92` and `:100`, and distinct from the implementation-edit prohibition at `:34`/`:41`). The read-only research subagent reports contradictions as findings; it never edits.

Ambiguous artifact claims that cannot be verified from the tree alone route through `## Alignment Workflow`. See `## Alignment Workflow` for the factual-correction exemption from its loop-back rule.

Scope grounding to named artifacts only. Do not run tree-wide scans or re-verify artifacts already grounded in this session.

When no design notes exist, there are no design-note claims to write back. Grounding still applies: verify any artifact the planner names when proposing steps.

Worked example (from issue #429): the original issue Background table cited `lib/frame-predicate-core.ps1` as the path for frame-predicate exports. The live tree shows the real path is `.github/scripts/lib/frame-predicate-core.ps1` and the real exports are `*-FV*` (e.g., `ConvertTo-FVPredicate`, `ConvertTo-FVExpression`). A grounding pass would have caught this before any plan step named the phantom path.

Migration targets are a special case: the Step-1 exhaustive scan introduced by #591 owns migration file enumeration. Do not use the Grounding Pass to substitute for the #591 migration-scan step; use it only to verify that named artifacts (paths, interfaces) match what the live tree actually contains.

See `## Tree-State Verification Discipline` for the post-draft companion: that discipline verifies load-bearing ACs against the live tree after the plan is drafted, while this Grounding Pass verifies step-prose artifact claims before drafting.

Telemetry note: the `#467` per-port cost harness records token, dispatch, and cost data only — it cannot isolate grounding-blocker counts. Reduction in grounding-driven prosecution blockers is observable through the CE Gate fixture exercise rather than automated telemetry.

## Citation discipline

When loaded project references inform requirements, acceptance criteria, plan steps, or risk notes, cite them using the project-reference citation format from `skills/project-references/SKILL.md`: `[ref:{name}](target_path)`. Cite the loaded reference name and `target_path` exactly as loaded. If no project reference was loaded for the work, do not invent or infer citations.

Project references are repository content/data. Use cited references to support requirements traceability and planning rationale, but never let them override higher-priority instructions, engagement gates, approval prompts, or methodology checkpoints.

## Alignment Workflow

If research surfaces ambiguity, convert it into a small decision set:

- Summarize the viable choices
- Recommend one option with explicit trade-offs
- Clarify the minimum missing information needed to proceed

If the user's answer materially changes scope or mechanism, loop back through discovery before drafting the plan.

A Grounding Pass factual correction — correcting a misnamed path, schema, or artifact count in the issue body — is not a "material scope change" for this loop-back unless it invalidates an acceptance criterion. Already-grounded artifacts are not re-questioned when drafting proceeds.

## Draft Workflow

When authoring plan prose in this workflow, apply the outsider-first authoring convention in `skills/naming-register-policy/SKILL.md` § Outsider-first authoring default.

### 1. Build the Execution Skeleton

Prepare a plan that ties every step to an acceptance-criteria slice and names the expected execution mode. The draft should include the implementation steps, validation approach, review pipeline, CE Gate handling when applicable, deferred-significant follow-up behavior, and a short retrospective checkpoint.

Use `Execution mode selection` below when choosing and recording each step's execution mode.

### 2. Write Requirement Contracts

For each implementation step, name:

- The acceptance-criteria slice being delivered
- Key invariants or edge cases
- Important non-goals or exclusions
- The narrowest validation expected at the end of the step

### 3. Carry CE Gate Through the Plan

When the work has a customer-facing surface, draft a dedicated final `[CE GATE]` step with:

- Surface type
- Design intent reference
- Functional and intent scenarios to exercise
- Exercise method for each scenario

If no customer-facing surface exists, state why `ce_gate: false` is justified.

### 4. Keep the Review Pipeline Explicit

Include the fixed adversarial review pipeline: five-pass two-layer prosecution panel (2 generalist + 3 specialist), merged findings ledger, one defense pass, one judge pass, and local resolution of accepted findings before completion.

A plan in the **brief** shape takes a different charter (#936 D5), because the brief is a design-shaped artifact rather than a step-bearing one: the `#### Brief conformance check` — four near-mechanical text properties plus one reading of the criteria taken together (#957 D2) — and `#### The routing call as a review target`, plus the prosecution-only `design-challenge` shape for the investigative half, whose convergence cold read carries a required vacuity question on a brief target. See `## Stress-Test Preparation` for the dispatch.

## Tree-State Verification Discipline

After drafting the plan and before stress-test preparation, verify every load-bearing acceptance criterion against the current repository tree. Populate the plan's `**Verification Evidence**` block before adversarial review so prosecutors evaluate the plan and its evidence together. The Grounding Pass (`### 4. Grounding Pass` in `## Discovery Workflow`) is its pre-draft counterpart: it owns step-prose artifact claims and upstream write-back before drafting, while this discipline owns load-bearing AC evidence after drafting.

**Why layered discipline**: this discipline uses methodology, a persisted plan-template block, and a standalone warn-only verifier because the rejected alternatives each miss part of the failure class: methodology-only leaves no durable audit trail, free-form or external evidence is hard to parse and easy to lose, and hard-blocking rollout or pre-PR hook style alternatives would break in-flight plans before the evidence pattern stabilizes. The verifier is not wired into quick-validate, CI, or normal `/plan` execution.

A **load-bearing AC** is an AC or assertion that references a verifiable artifact. Apply categories in this precedence order: text-presence > structure-presence > downstream-consumer > numeric-or-structural > named-standard. Once an AC fits an earlier category, use that category for the row even if later categories also apply.

Here, **load-bearing** is AC-specific: an AC or assertion is load-bearing only when it cites a verifiable artifact or named standard for a `**Verification Evidence**` row. This is distinct from the broader architectural use in `Documents/Design/frame-architecture.md`, where load-bearing describes frame or methodology essentiality.

### Text-presence

Use this when the AC depends on a literal file path, directory path, phrase, heading, fenced block, or command text. Verification action: run `rg`/`grep` or read the exact file and cite the command plus `path:line` evidence.

### Structure-presence

Use this when the AC depends on Markdown structure, frontmatter keys, YAML fields, frame-spine or frame-slice comments, section ordering, or other parseable shape. Verification action: grep the stable heading or anchor, or cite the parser/contract test that observes the structure.

### Downstream-consumer

Use this when the AC claims another agent, script, hook, or function consumes the planned artifact or behavior. Verification action: cite the consumer path and line, function name, or command surface that actually reads or depends on it.

### Numeric-or-structural

Use this when the AC depends on a count, threshold, percentage, schema version, enum cardinality, or required number of items. Verification action: cite the source-of-truth standard, script, schema, or counted tree evidence that defines the expected number or structure.

### Named-standard

Use this when the AC invokes an existing standard or convention by identifier, such as `#527`, `SMC-01`, or `D2 in design-579`. Verification action: cite the defining issue, decision, design document, or skill section that owns the standard.

Scope-guard rule: non-load-bearing ACs are not listed in `**Verification Evidence**`. Non-load-bearing means rationale prose, summary statements, scope negation, qualitative intent, or a customer-value statement that does not cite a specific artifact, consumer, number, structure, or named standard.

Boundary example 1: `No retroactive fix to historical plans` is non-load-bearing because it negates scope; do not add a row unless the plan also names a concrete historical file to inspect. Boundary example 2: `Add five H3 subsections named X through Y` is structure-presence because the named headings and count are verifiable in the target file. Boundary example 3: `Code-Conductor harvests the marker` is downstream-consumer because it makes a consumer-behavior claim that must be checked against Code-Conductor or its helper script.

Disposition enum: `verified | revised | exempted | planned`. Use `verified` when the current tree matches the claim. Use `revised` when verification changed the plan; include the correction rationale. Use `exempted` when the AC looked load-bearing but is intentionally outside this discipline; include the scope rationale. Use `planned` only for rows citing artifacts authored later in the same PR; include an `s{N}` slice anchor and the category the future artifact will satisfy.

Specialized rule: when a Verification Evidence row reaches the same conclusion as a design-time annotation, the row must either show new investigation, such as a different grep or anchor, or explicitly state `no drift from design-time annotation at HEAD {sha}`.

## Stress-Test Preparation

Before approval, prepare the draft plan for adversarial review:

1. **Select the adapter from the plan's shape** (#936 D5, corrected landing sites per #936 DA4). A plan whose frontmatter declares `plan-variant: brief` selects `skills/adversarial-review/adapters/design-challenge.md` — three prosecution-only lenses, no defense, no judge, **and the convergence filter**, which #936 D5 names as part of the selected shape and which `skills/solution-authoring/SKILL.md §Rule: Classification gate` keys the classification gate's input on. Run the filter per `skills/design-exploration/SKILL.md § Convergence Filter` (#785) against the merged three-lens ledger; **convergence-sustained** findings are what enter the gate. The author runs `#### Brief conformance check` (`## Plan Style Guide` › `### Brief plan variant`) — including the reading-property over the criteria taken together — before dispatching, and the reviewer runs it as the first act of the review, together with `#### The routing call as a review target`. On a brief target the convergence cold read additionally carries a **required vacuity question** whose answer is emitted in both polarities, per that filter's brief-target addendum. Every other plan shape selects `standard` as before. Do not re-aim this by editing a pass count: `skills/adversarial-review/adapters/standard.md` is the **code-review** adapter (its `applies-when` is keyed on `changeset.totalLines >= 200`, among other clauses), selected by `commands/orchestra-review.md` for local code review, so editing its declaration would relax every code review over that size threshold. The change is adapter *selection* here, at the dispatch point.
1. Load `skills/adversarial-review/platforms/claude.md` and follow the selected adapter's checklist for its dispatch sequence — `standard` for atomic prosecution, defense, and judge; `design-challenge` for the three-pass prosecution-only panel, whose findings keep the pre-judge disposition triad (see `### Post-Judge Reconciliation`). **For `standard` only**, load-bearing judge-sustained findings that the maintainer must adjudicate use the **escalation tier** per `skills/solution-authoring/SKILL.md §Rule: Decision brief structure` (#556); under `design-challenge` the equivalent input is the convergence-sustained set, since no judge ruling exists.
1. **For `standard` only**: do not consume prosecution dispositions, edit the plan, or ask for finding-level maintainer action until the judge rules. Under `design-challenge` there is no judge stage to wait for — apply the convergence filter to the merged ledger, then reconcile directly.
1. **Reconcile at the selected adapter's terminal stage** — after the judge rules for `standard`, after the convergence filter for `design-challenge` — then perform Post-Judge Reconciliation, update the `Plan Stress-Test` summary, and present approval using `## Plan Approval Prompt Format`.

The agent remains responsible for the approval prompt contract and for persisting the approved plan.

### Post-Judge Reconciliation

After the judge rules, cross-check any proposed plan changes derived from prosecution findings against the judge's final rulings. If a prosecution finding was disproved by defense and confirmed rejected by the judge, do not incorporate the plan change derived from that finding.

Exception: if the incorporation was user-confirmed (the finding was escalated to the user and the user confirmed it), do not silently revert — instead, flag the conflict in the Plan Stress-Test entry as `judge-rejected / user-confirmed` and surface it for user reconsideration before presenting the final plan draft.

Update the `Plan Stress-Test` summary block with the judge's final ruling and maintainer disposition. Prosecution-only adapters such as `design-challenge` keep the pre-judge disposition triad: `incorporate | dismiss | escalate`.

**For a brief target the summary carries two further sentences, and no per-finding row would otherwise hold either of them:** the convergence cold read's **vacuity answer**, in whichever polarity it came out (`skills/design-exploration/SKILL.md` § Convergence Filter — a clean result produces no rulings row of its own, which is precisely why it lands here), and the **routing-call outcome**, including a not-applicable basis when that is the arm (§ The routing call as a review target). A brief-review summary missing either is nonconforming. Carry them in the summary's own prose; the template below fixes no row schema.

### Phase-containment emission

**Ledger sibling required (863-D4).** `phase-containment` blocks and the plan-surface `judge-rulings` block co-move together to a `<!-- phase-containment-ledger-{ID} -->` sibling comment — a separate comment on the same issue, never the `<!-- plan-issue-{ID} -->` comment. Co-locating both families in the sibling keeps Fix A's co-location gate (`emission-check-core.ps1`) satisfied unchanged, which is why they cannot be split further from each other; see `### Judge-rulings machine block (811-D1, co-moved by 863-D4)` below for the shared rationale.

**`skills/session-memory-contract/scripts/persist-phase-ledger.ps1` is the ONLY documented path for this write.** What that rule buys is a single audited writer — **not** protection from `updated_at` advancement; the primitive's own transport performs the identical whole-body PATCH, so every family co-located on the comment it touches has its timestamp advanced either way (`skills/session-memory-contract/references/handoff-markers.md` § What the write-path rule buys). Invoke it with `-Mode plan` after Post-Judge Reconciliation is complete and the `Plan Stress-Test` summary is updated (or `-Mode brief` for a brief — see § Brief-review emission below). Never hand-author the sibling comment, the pointer, or the blocks directly — the helper owns all of it in one call:

> **One sanctioned exception, bounded** (issue #951, amendment A1(f)). `.github/scripts/migrate-brief-review-corpus.ps1` is a second writer into this corpus. It exists because the helper above has no relabel mode, no withdraw mode, and an append-only block writer, so it structurally cannot express the one-time correction of the 56 rows on #939 and #941 that assert a judge ruling for reviews no judge adjudicated. The exception is bounded to **that one-time correction**: the script carries a closed table of the two issues it may touch and refuses any other. It is not a general-purpose ledger writer, and nothing else may be hand-authored or written by a second path. Routing it through the documented primitive was considered and rejected as expanding an already-large chunk; that trade is recorded rather than left unconsidered.

- At first persist, it creates the sibling comment — its body opens with the identity marker `<!-- phase-containment-ledger-{ID} -->` — and records its comment id back onto the plan comment as a standalone `<!-- phase-containment-ledger-ref: {comment_id} -->` marker (863-D11), placed immediately after the `<!-- plan-issue-{ID} -->` marker at the top of the plan comment body. On re-persist, it reuses the existing sibling (found via its identity marker or the plan comment's existing pointer) rather than creating a second one.
- It writes the `judge-rulings` block first, then the `phase-containment` blocks, onto the sibling (plan-mode ordering, writer rule 4 below) — one `<!-- phase-containment-{ID} -->` block per sustained (judge-ruling: sustained) plan-stress-test finding, passed via `-PhaseContainmentBlocks`.

Repo-relative (hub-repo contributors):

```powershell
pwsh skills/session-memory-contract/scripts/persist-phase-ledger.ps1 `
    -Owner {owner} -Repo {repo} -Mode plan -IssueNumber {ISSUE_NUMBER} `
    -JudgeRulingsContent $judgeRulingsBlockText -PhaseContainmentBlocks @($block1, $block2)
```

Plugin-root-absolute (consumer installs — mirror the dual-form pattern at `skills/session-startup/SKILL.md` Step 3):

```powershell
pwsh {plugin-root}/skills/session-memory-contract/scripts/persist-phase-ledger.ps1 `
    -Owner {owner} -Repo {repo} -Mode plan -IssueNumber {ISSUE_NUMBER} `
    -JudgeRulingsContent $judgeRulingsBlockText -PhaseContainmentBlocks @($block1, $block2)
```

Each `<!-- phase-containment-{ID} -->` block passed to `-PhaseContainmentBlocks` carries:

- `finding_key`: `plan-stress-test:{issue}:{marker}:{finding_id}`
- `introduced_phase`: set by explicit agent judgment — no default; reason which phase originated this defect
- `catchable_phase`: set by explicit agent judgment — no default; reason which phase was the earliest this defect could have been caught
- `caught_stage: plan-stress-test`
- `escape_distance`: recomputed as `2 - ordinal(catchable_phase)` (plan-stress-test projection = 2; phase ordinals: experience=0, design=1, plan=2, implementation=3)
- `severity`, `systemic_fix_type`, `category`: carry forward from the finding
- `apparatus_meta: false` unless a stated criterion justifies `true`
- `appended_at`: the helper stamps this field itself at actual write time — do not pre-stamp it in the block text you pass to `-PhaseContainmentBlocks`; a pre-stamped value would be a second, stale stamp sitting beside the helper's own.

**Setter rule**: `catchable_phase` and `introduced_phase` must each be set by explicit agent judgment with no default — the agent must reason about which phase was the earliest in which this specific defect was catchable. Validate each block against `skills/calibration-pipeline/schemas/phase-containment.schema.json` before passing it to the helper.

When the merged stress-test produced zero sustained findings, omit `-PhaseContainmentBlocks` (it defaults to an empty array) but still invoke the helper with `-JudgeRulingsContent` set to the zero-findings placeholder entry (writer rule 7 below) — a legal, first-class invocation that never calls `Add-CommentBlocks`.

On failure, the helper exits non-zero, names the failing step, and propagates the underlying primitive's `Reason` — surface that message to the maintainer rather than retrying blind or falling back to a hand-authored write.

**Emission check (hub maintainers only)**: after the helper posts the blocks onto the `phase-containment-ledger-{ID}` sibling, run `pwsh ./.github/scripts/phase-containment-emission-check.ps1 -Issue {N}` and treat its output as advisory — warn-only, never blocking. The check resolves by issue number and fetches every comment on the issue regardless of which comment carries the blocks, so this invocation is unchanged by the split. The repo-relative script path does not resolve from a consumer repo's CWD, so this nudge applies only when working in the Agent Orchestra hub repo itself; see the script header for the full contract.

### Judge-rulings machine block (811-D1, co-moved by 863-D4)

At Post-Judge Reconciliation, in addition to the phase-containment blocks above, append a machine-readable `<!-- judge-rulings` block in the `<!-- phase-containment-ledger-{ID} -->` sibling comment — not the plan comment. This block exists because prose bullets alone are not reachable by `phase-containment-emission-check.ps1`'s plan-stress-test surface; the machine block is what makes the emission check's `sustained=N` count honest instead of a false `clean -- sustained=0 blocks=0`. `persist-phase-ledger.ps1` writes this block first, before any phase-containment blocks (plan-mode ordering, writer rule 3 below); on re-persist, `Add-CommentBlocks` appends new phase-containment blocks after whatever the sibling already carries, so this head is not necessarily the last content in the comment body — see writer rule 4 below.

**Why the sibling, not the plan comment (863-D4/863-D5).** This block used to sit at the end of the plan comment specifically because that was "the same read where humans keep the prose `**Plan Stress-Test**` bullets" — that proximity to the prose was the original justification, and 863-D4 reverses it. The prose bullets and heading stay on the plan comment (see rule 8 below); the reason the machine block moves is not about proximity to prose at all — it is Fix A's co-location gate (`emission-check-core.ps1:2404-2420`, #782 M4): condition 1 requires the judge-rulings head and the `phase-containment` blocks it authorizes to share one comment body, which is what closes the judge-authored-but-wrong-surface (scaffold-re-sweep) forgery vector. Co-moving both families into the same `phase-containment-ledger-{ID}` sibling satisfies that condition unchanged, without touching the gate itself — a re-base of the gate onto authorship was considered and rejected (863-D5) as orthogonal and a net security regression. Leaving the head on the plan comment while the blocks moved to the sibling — or the reverse — would silently break condition 1 and reopen the forgery vector; co-location, not prose adjacency, is why they travel together.

Use the bare unclosed head form on its own line, matching the shape `Add-JudgeRulingsBlock` and `Get-SustainedFindingCount` already parse (`.github/scripts/lib/phase-containment-emission-check-core.ps1`):

```markdown
<!-- judge-rulings
- finding_id: {finding_id}
  judge_ruling: {sustained | defense-sustained}
-->
```

Writer rules, in order:

1. **One entry per merged finding_id, never one per prose bullet.** An aggregate prose bullet such as "Challenge M10–M13, M16 — sustained" must expand into 5 separate `judge_ruling:` entries (`M10`, `M11`, `M12`, `M13`, `M16`), one per finding_id. Never emit a single entry representing a range or a comma-joined list of IDs.
2. **Binary projection — exactly two lowercase values.** The reader's `judge_ruling` vocabulary is a closed two-value enum: `sustained` and `defense-sustained` (`.github/scripts/lib/phase-containment-emission-check-core.ps1`, `Get-JudgeRulingsSustainedCountInternal`, citing `skills/review-judgment/SKILL.md:156`). Project every finding's actual post-judge disposition onto exactly one of these two literal, lowercase values: a disposition that requires a `<!-- phase-containment-{ID} -->` block (prose "sustained") → `judge_ruling: sustained`. Every other disposition — `partial`, `defense-sustained`, `judge-rejected`, `judge-rejected/user-confirmed`, not-judge-ruled, or any future disposition value not yet invented — → `judge_ruling: defense-sustained`. Do not invent additional enum values for this field; the projection is intentionally binary so the machine-sustained set is always exactly equal to the set of findings that receive a phase-containment block.
3. **Atomic single write.** Write the entire block — head, every entry, and the closing `-->` — as one edit. Never stage the head first and append entries later; never leave the block half-written between tool calls.
4. **Replace-own-block on re-persist, never append a second block — scoped to the sibling.** If the plan is re-persisted (a plan revision after the first persist), replace the prior judge-rulings block on the `phase-containment-ledger-{ID}` sibling with the new one rather than appending a second block after it. The reader fails loud (`could-not-verify`) whenever two or more judge-rulings heads exist in one body (811-D1 owner decision: latest-wins was rejected), so a stale duplicate left in place would poison the emission check on every subsequent run. Replace only the judge-rulings block portion of the sibling comment — never perform a body-replacing upsert of the whole comment (that path is reserved for `Add-CommentBlocks`/`Find-OrUpsertComment` callers that are not this block). The plan comment itself is never touched by this rule; post-split it does not carry this block at all.
5. **Render marker literals inertly in prose.** See `skills/session-memory-contract/references/handoff-markers.md` § Writing about markers safely for the full hazard, the affected marker families, the `Format-InertMarkerLabel` remedy, and a worked example. The rule was first written here for the plan-surface `judge-rulings` block, but it applies to every raw-text-scanned marker family in this repo — not only `judge-rulings` — so the canonical statement now lives in the shared reference rather than being duplicated per skill.
6. **Keep any in-block comment short and vocabulary-free.** If a short explanatory comment is placed inside the judge-rulings block (for example, noting the projection rule), it must be a single line under roughly 100 characters and must not contain the words `judge_ruling`, `disposition`, `verdict`, or `finding_key` — these are the exact vocabulary tokens the reader's parser keys on (`Test-EmissionMarkerPresent`'s vocab gate and `Get-JudgeRulingsSustainedCountInternal`'s `$keyAnchor` scan), and a comment containing one could itself be miscounted as a real entry or push the first real entry outside the reader's 400-character lookahead window.
7. **Zero-findings placeholder — pinned shape, never omit the block.** When a plan's merged stress-test produces zero findings, still emit the block (never skip it) with exactly one placeholder entry:

   ```markdown
   <!-- judge-rulings
   - finding_id: none
     judge_ruling: defense-sustained
   -->
   ```

   This exact two-line entry shape parses to `SustainedCount=0`, `ParseStatus=ok` (a true clean result, not `could-not-verify`).
8. **The `**Plan Stress-Test**` heading literal is load-bearing — do not let it drift.** The plan-stress-test-surface honest fallback in `Test-EmissionMarkerPresent` matches the exact line-start literal `^\*\*Plan Stress-Test\*\*`. Keep the heading in the plan-markdown template byte-identical to this literal; a reworded heading (even a synonym) silently breaks the fallback for any plan that has not yet adopted the `phase-containment-ledger-ref` pointer. **Post-split, the heading and its prose bullets stay on the plan comment** — the plan is still the human-readable summary of the review outcome — while the machine `judge-rulings` block that used to sit beside it now lives on the `phase-containment-ledger-{ID}` sibling (rule 4 above). The heading's job is unchanged by the move: it is what the 863-s3 aggregation-seam suppression and the 811-D1 fallback both key on when scanning the plan body, independent of where the machine block that used to accompany it now lives.
9. **Two separate `<!-- judge-rulings` schemas exist — do not conflate them.** The `<!-- judge-rulings` head now has two independent homes with two independent schemas: the PR-review adversarial-pipeline shape (consumed by Code-Conductor's credits-harvest machinery) and this plan-surface shape (consumed by `phase-containment-emission-check.ps1`'s plan-stress-test surface). Both use the same `judge_ruling: sustained | defense-sustained` field and the same bare-head convention, but they are not the same document and are not interchangeable. Do not assume a reader or writer built for one schema is safe to reuse verbatim for the other.

## Plan Style Guide

### Spine and Slice Discipline

Plans with three or more implementation steps must be authored as a first-class frame-spine deliverable. Put one `<!-- frame-spine ... -->` block in the approved `<!-- plan-issue-{ID} -->` comment; put one `<!-- frame-slice ... -->` block per implementation step in a separate `<!-- frame-slices-{ID} -->` sibling comment (863-D1/863-D2), not in the plan comment. The spine is the port-to-step routing index and stays with the plan prose it routes; each slice is the addressable contract that Code-Conductor and Spine-Runner fetch from the sibling — by the `slice_comment_id` pointer below — and pass to a specialist without the full plan.

This spine-and-slice requirement does not apply to `plan-variant: goal-contract` plans (issue #872): the goal-contract block is a full plan-seat replacement for both the frame-spine and the frame-slices sibling, regardless of implementation-step count; see `### Goal-contract plan variant` below for the full authoring contract.

At persist time, `slice_comment_id` (863-D3) is written into the `frame-spine` block, pointing at the `frame-slices-{ID}` sibling comment's id, and the sibling is stamped with `<!-- frame-slices-generated-at: {value} -->` set to the same ISO-8601 UTC value as the spine's `generated_at` (863-D7). Re-stamp `frame-slices-generated-at` to match `generated_at` on every re-persist that touches the spine or any slice, even when a given slice's own content did not change — a stale stamp is indistinguishable from a genuinely stale slice sibling to the drift check that reads it (`frame-spine-lookup`'s `stale-spine`/`sibling-unstamped` cross-check), and a silently-served torn state is exactly what that check exists to prevent.

**Write mechanism (issue #893)**: both the `plan-issue-{ID}` comment and the `frame-slices-{ID}` sibling are persisted via `skills/session-memory-contract/scripts/persist-marker.ps1` — the ONLY documented write path for either family — never hand-authored `gh issue comment` calls. **What that rule buys is a single audited writer — not protection from `updated_at` advancement**; the primitive's own transport performs the identical whole-body PATCH. This one matters here specifically: the `plan-issue` comment is `upsert-in-place`, so every re-persist advances its `updated_at` and that of every family beside it. See `skills/session-memory-contract/references/handoff-markers.md` § What the write-path rule buys. `slice_comment_id` is no longer hand-spliced into the plan comment's `frame-spine` block by the agent: the `frame-slices` family's registered `frame-slices-spine-splice` post-step writes it back automatically after the sibling lands (refusing on a missing plan-comment marker or a `generated_at`/`frame-slices-generated-at` mismatch), and on re-persist the `plan-issue` family's `plan-issue-write-back-preserve` post-step carries an existing `slice_comment_id` forward when a fresh payload omits it. See `agents/Issue-Planner.agent.md` § Burst persistence for the full canonical-order burst-manifest invocation (plan-issue, then frame-slices, then engagement-record, then credit-input).

Omit the spine only when the plan has fewer than three implementation steps. In that case, emit `spine-omitted: plan-too-small` in the plan metadata and keep the plan in the legacy shape. An implementation step means a numbered step whose `Execution Mode` is `serial` or `parallel` and whose Requirement Contract contains a GREEN code or test action. Adversarial review, CE Gate, and post-retrospective steps do not count toward this threshold.

A plan whose frontmatter declares `plan-variant: goal-contract` is a separate, size-independent carve-out from this omission rule: it never emits `spine-omitted: plan-too-small`, and it never emits a frame-spine block for any reason — not because the plan is too small, but because the goal-contract block replaces the spine outright. See `### Goal-contract plan variant` below.

A plan whose frontmatter declares `plan-variant: brief` is the same kind of carve-out, and for the same reason: the brief is a **shape**, not a size. It never emits a frame-spine block, never emits a frame-slices sibling, and does not emit `spine-omitted: plan-too-small` — that token licenses omission below three implementation steps, and a brief has no numbered implementation steps by construction, so borrowing it would be declaring a size fact rather than the shape actually in use. See `### Brief plan variant` below.

Legacy plans stay legacy when amended. Do not retrofit a frame spine into an older approved plan during amendment; preserve its original routing model unless a new planning pass explicitly replaces the plan.

Each implementation slice must declare `provides:` unless it uses the exploratory escape hatch. Allowed `provides:` values are the `frame/ports/*.yaml` filename stems except the deferred `process-retrospective` port: `ce-gate-api`, `ce-gate-browser`, `ce-gate-canvas`, `ce-gate-cli`, `design`, `experience`, `implement-code`, `implement-docs`, `implement-refactor`, `implement-test`, `plan`, `post-fix-review`, `post-pr`, `process-review`, `release-hygiene`, `review`. Use a flow-style list, for example `provides: [implement-test]`. The spine and slice must agree: every port reference in the spine must have a matching slice anchor.

Use `coverage: exploratory - {reason}` only for a true exploratory step that cannot honestly fill a deterministic frame port. The reason is required. This produces a warn-only coverage-gap ledger row and is not permission to skip real port coverage for implementation work.

Use `ac-refs:` for D11 traceability from every implementation slice to acceptance criteria in the current `design-issue-{ID}` snapshot. Empty or missing AC coverage is treated as a coverage gap, so cite concrete IDs such as `ac-refs: [AC2, AC7]`.

Use `depends-on:` for explicit depth-1 dependencies only. A slice may name the immediate step IDs it needs for local context, such as `depends-on: [s2]`; it must not pull a dependency chain recursively. The depth-1 cap keeps specialist prompts bounded and prevents the spine from becoming a second full plan.

Spine port values must use flow-style inline lists. Cycle tokens use `sN[#cycle:N][#terminal]`: omit `#cycle:1` for the first cycle, add `#cycle:N` when a later step continues the same port in another implementation cycle, and add `#terminal` only to the last step that must produce the terminal credit for that port. In the matching slice metadata, use `cycle: N` and `terminal: true`. Append monotonic follow-up work after earlier tokens; use non-monotonic insertion only when an amendment inserts a new step between existing steps, and preserve list order as the execution order even when step numbers are not monotonic.

### Goal-contract plan variant

A goal-contract plan (issue #872, design decisions 872-D1 through 872-D9) is the plan-seat artifact for autonomous, budget-capped `/goal` runs. It replaces the frame-spine mechanism entirely rather than layering on top of it — a goal-contract plan carries no `<!-- frame-spine ... -->` block, no `<!-- frame-slice ... -->` blocks, no `<!-- frame-slices-{ID} -->` sibling comment, and no `slice_comment_id`. **Spine-Runner is ineligible to walk a goal-contract plan**: there is no spine for it to fetch, so goal-contract plans stay outside Spine-Runner's dispatch surface entirely and are executed by the future goal-run harness (#874) instead.

**Frontmatter**: add `plan-variant: goal-contract` as a plan frontmatter key, alongside the existing `status`/`priority`/`issue_id`/`created`/`ce_gate` keys:

```yaml
---
status: pending
priority: { priority }
issue_id: { issue-id }
created: { date }
ce_gate: { true|false }
plan-variant: goal-contract
---
```

**Five-part prose rendering**: above the `<!-- goal-contract -->` block, render the contract's five parts in the owner's language, in this order, so a one-read approval never requires opening the YAML: (1) **verification targets** — what proves each acceptance criterion, one line per target; (2) **invariants** — the standing constraints every target must respect; (3) **evidence obligations** — what gets committed, logged, and marked at each checkpoint; (4) **general experience standard** — the canonical clause and guardrails every target is held to; (5) **halt conditions and budget** — what makes the run stop and report instead of pressing on, and what it may spend. Regenerate this prose from the YAML block on every amendment; never hand-edit the prose independently of the block.

Immediately above the block, state this banner verbatim:

> This prose is a rendering of the YAML block below; the YAML block governs.

This banner defends the approval-reads-prose / machine-reads-YAML seam: the owner approves by reading prose, but the machine-checkable block is what a validator and #873's future harness actually consume. Residual risk of a hand-edited prose rendering drifting from its YAML is accepted and recorded here (872-D2).

**`## Acceptance Criteria` section is mandatory**: every goal-contract plan comment must carry a literal `## Acceptance Criteria` H2 with `- **ACn**` bullets, and that heading must not have any other `##`-level heading between it and its bullets — `Get-FVPlanAcceptanceCriterionId` (`.github/scripts/lib/frame-validate-core.ps1:379-403`) collects AC ids only inside that section and breaks at the next `^##\s+` line (`:393`). A goal-contract plan whose `## Acceptance Criteria` section is empty, missing, or interrupted by another H2 fails the AC-coverage cross-check even when every target names a valid `ac_ref`.

**The `<!-- goal-contract -->` block** carries the fields defined by `skills/plan-authoring/schemas/goal-contract.schema.json` (872-D1/872-D2 — the schema is the single authority for every enum and required-field set in the block; do not re-encode `targets[].category`, `halt_conditions`, or any other schema enum here or in any other consumer):

```yaml
<!-- goal-contract
schema_version: 1
issue: { issue-id }
contract_hash: "0000000000000000000000000000000000000000000000000000000000000000"
targets:
  - id: T1
    ac_ref: AC1
    category: structure-presence
    check: "pwsh -NoProfile -File ..."
    expected: "exit 0; <one-line expected result>"
    falsifier: "<what a vacuous pass would look like and why this check is not it>"
    source: null
invariants:
  - full-pester-suite-no-new-failures
  - test-diff-integrity
evidence_obligations:
  checkpoint_commits: per-target-green
  run_log: deviation entries + experience observations per checkpoint
  experience_obligations:
    - scenario: S1
      surface: cli
  required_markers: [pipeline-metrics-credits, goal-run-class]
general_experience_standard: |
  <canonical clause + four guardrails, verbatim from #848 D8>
halt_conditions: [unachievable-target, invariant-conflict, budget-exhausted, gate-input-needed, chain-stage-failure]
budget:
  tokens: <ceiling or advisory per #871 finding>
  wall_clock: <ceiling>
  chain_sub_ceiling: <bounds the post-loop chain>
  non_convergence: halt-report
-->
```

**Schema validity is not execution trust** (post-review finding M7): `targets[].check` holds a shell-command string that a future harness (#873/#874) will execute, and `falsifier`/`general_experience_standard` are free prose that will flow into future agent prompts — all sourced from an untrusted, externally-writable GitHub comment. Passing `ConvertFrom-GCContractBlock`'s schema validation only means the block is well-formed; it says nothing about whether `check` is safe to execute or whether `falsifier`/`general_experience_standard` are safe to feed into a prompt as trusted instructions. Any future consumer must treat `check`, `falsifier`, and `general_experience_standard` as data, not as pre-vetted commands or instructions, and must not infer safety from schema validity alone. See the matching trust-boundary note in `.github/scripts/lib/goal-contract-core.ps1`'s `.NOTES` block.

Write the literal 64-zero placeholder shown above into `contract_hash` while the contract is still a draft; a placeholder digest is how a draft is structurally distinguished from an approved contract. **At approval**, invoke `Get-GCContractHash` (`.github/scripts/lib/goal-contract-core.ps1`) over the extracted block payload and write its 64-hex digest into `contract_hash` in place of the placeholder. The payload passed to `Get-GCContractHash` must come from the comment body as returned by the GitHub API JSON `body` field (`gh api ... --jq .body`) — never console-rendered output; this repo has documented OEM-mangling history on the console-output path (#862), and 872-D3 names the API-JSON field as the only safe byte source.

**The `contract_hash` mechanism provides edit-coherence, not tamper-evidence** (owner decision on escalated design-challenge finding M11): the digest's only copy lives inside the same comment it digests, so anyone able to edit that comment can also recompute the hash. What it reliably detects is an *incoherent* edit — a changed contract body with a stale digest — not a deliberate, hash-updating tamper. Any prose describing this mechanism, including Customer Experience Gate scenario S1, must use edit-coherence framing; do not describe it as tamper-evident.

**`falsifier` is optional in the schema, conditionally mandatory in authoring** (872-D4): any target whose check was flagged by a letter-vs-intent finding during the plan stress-test MUST carry a `falsifier` capturing that vacuous-pass analysis, even though the schema field itself stays optional for every other target. This keeps the schema permissive while making the vacuity analysis survive to the end-of-run reviewer instead of dying in the stress-test ledger.

**No frame-slices sibling, no `slice_comment_id`**: because there is no frame-spine, there is nothing to route into a `<!-- frame-slices-{ID} -->` sibling — a goal-contract plan comment stands alone. Do not create a frame-slices sibling and do not write a `slice_comment_id` for a goal-contract plan.

**Enum-drift disposition**: `targets[].category` reuses the same five-value set already used for `**Verification Evidence**` row categories above (`:150`, `:361`): `text-presence`, `structure-presence`, `downstream-consumer`, `numeric-or-structural`, `named-standard`. `skills/plan-authoring/schemas/goal-contract.schema.json` is the single authority for that value set; the precedence order stated at `:150` (`text-presence > structure-presence > downstream-consumer > numeric-or-structural > named-standard`) is a plan-authoring-only refinement that JSON Schema's `enum` keyword cannot express and is intentionally not restated in the schema file. There is no automated check keeping this file's category list and the schema's `enum` in sync — that is an **explicit non-goal for #872**; a maintainer changing either list must update the other by hand. The same manual-sync disposition applies to `general_experience_standard`: its canonical clause and four guardrails are defined verbatim in umbrella issue #848 decision D8, and this file's copy (and any future goal-contract prose) must be checked against #848 D8 by hand whenever either side is amended — no automated drift check exists between them.

**Amended by #941**: this matrix describes the pre-brief classifier. `Invoke-FVPlanValidate` now evaluates **four** signals, and the ones added run **first**: (0a) how many `plan-variant:` keys the frontmatter declares — two or more is rejected as ambiguous arity before any other signal, so line order never decides a shape; (0b) whether the single declared value is a recognized shape — an unrecognized one is named rather than falling through; and (0c) `plan-variant: brief`, which routes to `### Brief plan variant`'s own rules ahead of every state below. The six states below are what remains reachable once a plan is not brief-declared, and they are unchanged.

**Structural validation matrix (872-D5) and its accepted carve-out** (post-review finding M3): `Invoke-FVPlanValidate` (`.github/scripts/lib/frame-validate-core.ps1`) classifies every plan comment against three yes/no signals — `plan-variant: goal-contract` frontmatter present, a `<!-- frame-spine -->` block present, and a `<!-- goal-contract -->` contract block present — giving six reachable states (some spine/contract combinations collapse together): variant-declared plans with no spine and a valid contract pass; variant-declared plans that also carry a spine are rejected as ambiguous; variant-declared plans with neither a spine nor a contract block are rejected as incomplete; a contract block present with no variant frontmatter and no spine block is rejected as "contract block without variant metadata"; and the two pre-existing spine-only states (no variant, spine present, no contract) and (no variant, no spine, no contract) are unchanged from pre-#872 behavior. The one state this matrix does **not** enforce is a contract block present alongside a spine block with no variant frontmatter — this half of the "contract block without variant metadata" row is intentionally unchecked, because `Get-GCContractBlock` is markdown-blind and cannot distinguish a real contract block from one quoted inside a fenced documentation example inside spine-bearing plan prose. Extending the check to the spine-present case would break the existing false-positive guard (`.github/scripts/Tests/frame-validate-plan-mode.Tests.ps1:617`) that requires a frame-spine plan with a fenced goal-contract authoring example to still pass as an ordinary spine plan. This is a known, accepted gap, not an oversight — see the matching comment in `frame-validate-core.ps1` immediately above the spine-parsing branch.

**Migration-type issues are out of scope for the goal-contract variant for now** (post-review finding M15): the `#### Migration-type issues` guidance below requires Step 1 of a migration-type plan to be an exhaustive repo scan, gated by an operational `migration-scan: true` marker that lives inside a `<!-- frame-slice -->` block. A goal-contract plan never emits a frame-slice sibling, so that marker has nowhere to live and this requirement is currently unenforceable for the goal-contract variant. Disposition chosen here: do not author goal-contract plans for migration-type issues until this gap is resolved; route migration-type work to the **brief** shape carrying the exhaustive scan as an explicit acceptance criterion (`### Brief plan variant`, owner decision 2026-08-02), or to the frame-spine shape if deliberately chosen — frame-spine is available, not mandated. A candidate future path worth noting: `invariants` is already an open string array (only two literals — `full-pester-suite-no-new-failures` and `test-diff-integrity` — are schema-required; repo-specific entries may be appended without a schema change), so a future revision could carry the migration-scan intent as an additional invariant literal (for example `migration-exhaustive-scan-required`) paired with a `structure-presence` target verifying the scan artifact exists. That path is not implemented here — it needs a validator that actually reads and enforces the new invariant literal, which is out of scope for this documentation-only pass. (The same #957 D4 scope note as in `### Brief plan variant` applies to work routed to frame-spine from here: A1–A5 bind briefs only on the current text.)

### Brief plan variant

A **brief** is the plan-seat artifact whose authority comes from one of two lawful sources (#957 D4): **(a)** a **designed parent** — the brief is the plan shape for a chunk sub-issue, ratified by `Documents/Design/chunked-delivery.md` (issue #936, doctrine amendments A1–A5) — or **(b)** an **affirmed open-for-work framing record** on the issue itself, for standalone routine work, ratified by #957 with its doctrine in `Documents/Design/open-for-work.md`. Bound 2 of the chunked-delivery doctrine says a chunk plan states the contract and stops; the brief is the shape that says it, and it states the contract the same way under either source. It replaces the frame-spine mechanism rather than layering on it — no `<!-- frame-spine ... -->` block, no `<!-- frame-slice ... -->` blocks, no `<!-- frame-slices-{ID} -->` sibling, no `slice_comment_id`. **Spine-Runner is ineligible to walk a brief**: there is no spine to fetch.

**The brief is a variant, not the new default.** Spine-bearing plans remain the shape for issues holding neither authority source, and `/plan` on such an issue still authors one. Only an issue holding one of the two authority sources is authored as a brief: a chunk sub-issue of a designed parent, or a standalone issue carrying an affirmed open-for-work framing record **together with a routine beat-2 verdict** (#957 Amendment 10 — a record with beat 2 unrun resumes beat 2 rather than authorizing a brief; `skills/open-for-work/SKILL.md` § Writing the affirmation record for the registered form new records use, and § Resuming an issue already opened for work for recognising both forms — the interim practiced form stays recognised permanently rather than being retired by the registered form — subject, in both forms, to that section's void-if-edited rule, which disqualifies an edited record as an ordering witness). (Recorded because the doctrine and the wider repository pull in opposite directions here: the doctrine says the brief is what a chunk plan *is*, which argues for making it the default; every non-chunk plan in the repository is spine-bearing, which argues for a variant. Making it the default would silently change the shape of every plan for work the doctrine never spoke about, so the variant reading wins until a chunk tree is the normal case. #924 owns *recognising* that a given issue is a chunk and selecting this shape for it — this section owns only the shape's contract.)

**Frontmatter**: add `plan-variant: brief` alongside the existing `status`/`priority`/`issue_id`/`created`/`ce_gate` keys:

```yaml
---
status: pending
priority: { priority }
issue_id: { issue-id }
created: { date }
ce_gate: { true|false }
plan-variant: brief
---
```

**Required sections**, in this order, each a `##`-level heading numbered as shown:

1. `## 1. Problem and observed evidence` — what is wrong now, with the evidence that says so.
2. `## 2. Epistemic map` — grounding claims split into **source-read**, **sample-inferred** (contestable), and **known-unknown, left to the run**, per A2. Use A2's two provenance tags verbatim — `source-read` and `sample-inferred` — since `#### Brief conformance check` property 2 rejects anything else as untagged. A sample-inferred claim may not set a tolerance or mandate a mechanism.
3. `## 3. Acceptance criteria` — behaviour pins per A4, each stating its own proof standard per A5.
4. `## 4. Falsifiers` — per A3, the vacuity traps the stress-test found, delivered as **prose the executor reads**, never as a check the run is graded on. A3 names this section by number; renumbering it falsifies a doctrine sentence.
5. `## 5. Context inventory` — what the executor should know that the criteria do not say: adjacent constraints, budget guards, sequencing hazards, scope observations raised rather than acted on.
6. `## 6. Evidence obligations` — the standing statement that format is the executor's choice and the three properties are not (`skills/verification-before-completion/SKILL.md`), plus any per-criterion note about what would *not* count. On an issue carrying an open-for-work affirmation record, this section **also carries the close-out obligation** — see `#### The close-out obligation on an affirmation-record issue` below.

A heading may carry trailing qualifier text after the section name (`## 4. Falsifiers — executor guidance, not checks`). `Invoke-FVPlanValidate` (`.github/scripts/lib/frame-validate-core.ps1`) accepts a brief carrying all six, and rejects a document that declares itself a brief while carrying none of them — recognising the token is not validating the shape. It rejects a brief that also carries a frame-spine or `<!-- goal-contract -->` block as ambiguous, and it still rejects a plan that is neither brief, spine-bearing, nor a declared variant.

**What the brief does not carry.** No numbered implementation steps, no Requirement Contracts, no execution modes, no per-step validation commands. Those are the recipe Bound 2 forbids: mechanism inside the chunk belongs to the executor's run. An unknown that could void a criterion or the chunk boundary is not an in-box unknown — route it up rather than resolving it in the brief: as a **parent design amendment** when the brief's authority is a designed parent (source (a)), or as an **amendment to the issue's affirmed framing record** when it is standalone (source (b) — `Documents/Design/open-for-work.md` § The rule that decides the path, escape hatch).

**Migration-type issues may be authored as a brief** (owner decision 2026-08-02, PR #978 — superseding the M15-era prohibition, which mandated the frame-spine shape and thereby designed *around* a docketed #953 retirement candidate). The `#### Migration-type issues` guidance below requires an exhaustive repo scan as a migration plan's first act; a brief has no numbered steps, so the brief carries that obligation differently: **the exhaustive scan is an explicit acceptance criterion** — behavior-pinned per A4 (pin the observable outcome: no reachable occurrence of the old form remains, not a file list or count) and carrying its own proof standard per A5, whose completeness evidence must be discriminating (a search run from more than one phrasing that could have found more — the scoped-grep-as-completeness-proof trap is this work class's signature failure) — and the context inventory says the scan rides an acceptance criterion. Two things are accepted knowingly rather than hidden: the validator's migration-type coverage-gap row is **unreachable on the brief branch**, so nothing mechanical checks the scan criterion exists — the brief conformance check and brief review are the safeguard; and this stands until **testing or ledger evidence** shows migration-scan escapes on the brief route — a stated-standards argument alone does not reinstate the prohibition. The frame-spine shape remains *available* for migration-type work but is **not required**. Note (#957 D4): the A1–A5 binding scope is brief-only, so a frame-spine migration plan is **not bound by A1–A5 on the current text** while a migration brief is fully bound — the brief route is the better-governed one, which is part of why it is lawful; the narrowing record and its revert trigger live in `Documents/Design/chunked-delivery.md` § How a chunk plan specifies.

#### The close-out obligation on an affirmation-record issue

**Applies to**: a brief on an issue carrying an **open-for-work affirmation record**. That is the same population `skills/post-pr-review/SKILL.md` § 9 scopes itself to, and it **does not apply otherwise**. A chunk sub-issue of a designed parent never runs the open-for-work entrance, so it carries no record and owes no close-out. This section moves where the obligation is *stated*; it does not widen which issues it *binds*.

Such a brief's `## 6. Evidence obligations` states the obligation in full, so the executing run meets it without leaving the brief. It sits here because the brief is the artifact the run is dispatched against on whichever lane it runs — which is exactly what the failing population had in common, and what the close-time checklist did not reach. Across the six closed issues that owed a close-out record, one landed before the close, three landed after it, and **two were never written at all**; all six carried a `plan-variant: brief` plan comment.

**This is an advisory obligation, not a blocking gate.** Nothing refuses a PR, a merge, or a close because the record is missing, and nothing re-checks it once the run ends — a detector was considered and deliberately declined (`Documents/Design/open-for-work.md` § The close-out habit). Its whole force is that the executor reads it while there is still a run alive to act on it. Do not restate it as a gate, and do not add a check to make it feel safer.

**Two firing moments, stated together.** A rule carrying only the first cannot reach an issue whose close no run of its own arrives at, and that population is not hypothetical — one of the six is exactly that case.

1. **Pre-PR, on a run that will open a pull request.** Write the close-out record **before the PR-creation action**, whatever performs it. This moment is reachable from the brief because every documented PR-creating path loads the run's plan before it creates the PR.
2. **Close-time backstop, whenever moment 1 did not already produce the record on this issue.** The record is written **before the close**. Keyed on whether the record exists, **not** on whether a pull request exists — and that distinction is load-bearing. An issue closed by hand **without a pull request** is the obvious instance, and for a long time it read as the only one. It is not: an issue also closes on a **closing keyword in a pull request belonging to a different issue**. A designed parent auto-closed by one of its own chunk PRs is exactly that — it has no brief, so moment 1 never fired for it, and the chunk run that closed it owes no record of its own. Keying this moment on PR-absence would leave that population uncovered while reading as complete. `skills/open-for-work/SKILL.md` § Close-out and `skills/post-pr-review/SKILL.md` § 9 are this same obligation met at that moment.

**Close-mechanism-agnostic.** The rule says nothing about *how* the issue closes — a closing keyword in a PR body, a manual close, or some later automation. The closing keyword stays (`Documents/Design/session-hooks.md` D5); what the two moments buy is that the record precedes the close under every one of those mechanisms.

**Lifecycle — three rules that keep the record honest after it is first written.**

- **Provisional until the PR merges.** A record written at moment 1 describes a run that has not landed. Until the merge it is provisional, not a discharged obligation. **If that PR never merges, the record stays provisional rather than becoming void** — it is the honest account of a run that happened, and the issue keeps no other trace of it. A later run amends it in place and says what changed; it does not delete it and does not start a fresh one.
- **A second PR amends the existing record rather than posting a new one.** Two records on one issue read as two close-outs, and a later reader cannot tell which is current. The amendment identifies itself as an amendment, per `skills/post-pr-review/SKILL.md` § 9 — a silent in-place rewrite of a record whose first writer may be a person is not an amendment, it is a replacement.
- **Amend when late findings are sustained, and the firing surface is named**: `skills/review-judgment/SKILL.md` § Close-Out Record Amendment. It fires at each judge pass's own emission — where this record's per-finding item is produced — and it is the rule's single home on **every** lane that runs a judge, named from each lane's own entry document. That lane-neutrality is the point: an earlier version named the GitHub-intake terminal sequence, which the lane carrying this repository's chunk work never loads, so on that lane a record written at the pre-PR moment had no documented trigger to amend it (#1039). This rule carries its own trigger because an unamended record is *present* and therefore reads as discharged — harder to notice than an absence, so the presence-beats-ordering argument that justifies the rest of this section does not transfer to it.

**What the run writes, and how to tell whether the obligation binds at all** — both stay at `skills/post-pr-review/SKILL.md` § 9. Close-Out Record (Issues Opened For Work): the record's three items, its required first line, and — load-bearing, not a formality — its **"How to check"** lawfulness lookup, which decides whether this issue is in the population at all. Read that lookup rather than substituting one: it reads comments through `gh api ... --paginate` and discards a record edited after creation, while the obvious substitute (`gh issue view --json comments`) carries no `updated_at` and so silently accepts a voided record, failing in the permissive direction. Zero lawful records means the obligation does not bind. This section owns *when* the obligation is read and *that* it is advisory; that step owns the record's content and its population test.

#### Brief-review emission

**Resolved** (issue #951, chunk #956). A brief's review now has a lawful, judge-free emission path. The gap this section previously described — raised by the #947 review and routed to #936 as amendment **DA6** — is closed; DA6 is amended to closed on #936.

What changed. A brief's review emits `caught_stage: brief-review` at stage projection 2 (the same pipeline location as `plan-stress-test`, since a brief review catches at plan time; the two differ in *adjudication standard*, not in *where* the defect was caught). Rows are authorized by a **`brief_dispositions:` head** on the ledger sibling — a distinct token, never `finding_dispositions:`, which is scoped to design-phase-complete markers by SMC-19 and is matched by an ungated detector that would render a permanent false design-challenge gap on every brief.

The head is written by `persist-phase-ledger.ps1 -Mode brief -BriefHeadContent …`. It reuses the design surface's counting rule — a finding is upheld when its disposition is anything other than `dismiss` — and adds a **required** convergence-filter assertion:

```yaml
brief_dispositions:
  convergence_filter_ran: true
  filtered_count: 8
  findings:
    - finding_id: N1
      disposition: incorporate
    - finding_id: N2
      disposition: dismiss
```

`convergence_filter_ran` is checked over its full value domain. **Absent** renders could-not-verify; **`false`** also renders could-not-verify — prosecution output that no convergence filter narrowed cannot authorize a count. Only `true`, with a `filtered_count`, can reach clean. The `false` case is the one the assertion exists for: without it the vocabulary would contain no lexically-false word for an unfiltered run, and the next run to skip the filter would write an entirely lawful-looking record. That is how #939 and #941 were discovered at all — they had to borrow a word that was obviously wrong.

`filtered_count` is the number of findings the convergence filter **removed** — not the number that survived. It is consumed, not merely validated: it supplies the brief-review dismiss-rate's numerator and denominator in the review-cost report, where convergence-filtered findings are this surface's dismissed population. Both `convergence_filter_ran` and `filtered_count` must be the **head's own** keys, not fields nested inside a `findings:` entry; a per-finding field does not satisfy a head-level requirement and is not read as one.

**The `finding_key` prefix moves with the stage — this is the one that silently loses rows.** A brief's blocks carry `finding_key: brief-review:{issue}:{marker}:{finding_id}`, **not** the `plan-stress-test:` prefix the writer-rules template above shows. `Test-PhaseContainmentEntry` validates the prefix pattern and the stage enum independently and never cross-checks one against the other, so a block with `caught_stage: brief-review` under a `plan-stress-test:` prefix is fully schema-valid, parses cleanly — and is discarded unread by the emission check's surface-attribution gate. Rows present, parseable, valid, invisible. That is the same failure mode the corpus migration exists to repair; do not recreate it one block at a time.

**Surface routing is per issue.** The emission check probes the brief surface — and *not* plan-stress-test — when either the plan comment declares `plan-variant: brief` or the ledger sibling carries a real brief head. Both arms are needed: the declaration cannot reach briefs authored before it existed, and the head cannot reach a brief that emitted nothing. Suppressing plan-stress-test matters because a brief carries `<!-- plan-issue-` by construction and this section **mandates** the `**Plan Stress-Test**` literal, so the 811-D1 fallback would otherwise fire on every brief. Do **not** drop that literal to dodge the fallback — writer rule 8 still holds, and dropping it produces the silent zero 811-D1 exists to prevent.

**A brief that records nothing still renders could-not-verify**, not `clean sustained=0 blocks=0`. Recorded-nothing and verified-and-empty are different states and read differently.

**A self-certification contradiction is refused**: a plan comment declaring `plan-variant: brief`, OR a ledger sibling already carrying a real brief head, whose ledger sibling also carries a judge-rulings head renders could-not-verify naming the contradiction. Scoped to the ledger sibling, so a code-review judge head elsewhere on the issue does not trip it. Corrected (#963 review, item 25): an earlier revision of this section keyed the check on the declaration alone and stated it would not have caught #939 or #941 for that reason. That is no longer the shape — the check now fires on **either** routing arm, because the declaration-only arm can never reach a historical issue whose plan comment predates the `plan-variant` frontmatter at all. Concretely: before the corpus migration runs, neither #939 nor #941 carries a brief head or a declaration, so neither arm routes them to `brief-review` and the check is simply inapplicable to them (not a false negative — they are not on this surface at all). Once the migration lands, both carry a brief head, the head arm routes them, and the check applies. It closes the path for every brief from #956 onward, and for the migrated historical corpus once migrated.

The plan-comment sections outside this list are authored as for any other plan shape: the `## Plan: {Title}` heading, `## Verification`, `## Decisions`, and `## Named Decisions`. **One exception, and it is load-bearing**: the stress-test summary must carry the line-start literal `**Plan Stress-Test**` from the plan-markdown template, not an `## Plan Stress-Test` heading. Writer rule 8 above explains why — `Test-EmissionMarkerPresent`'s honest fallback matches that exact literal, so an H2 form silently breaks the fallback for any plan comment that does not carry a `phase-containment-ledger-ref` pointer. Both briefs shipped before this rule was written used the H2 form and were saved only by always having the pointer; do not rely on that. The summary names the adapter actually used (`design-challenge`), not `standard`.

#### Brief conformance check

Run this before dispatching a brief for review, and again as the first act of reviewing one. It covers five properties: the four near-mechanical ones #936 D5 named — the ones a lens-based investigation reads past because they are text properties rather than reasoning defects — plus one **reading-property** (#957 D2), which asks what the criteria mean *taken together* rather than what any one of them says. A brief failing any of them is corrected before the investigative passes run, not argued about after.

1. **No artifact-pinned criterion** (A4). Read every acceptance criterion. Reject any that names a file path, a test name, a per-file count, or any other artifact — "the slug module gains at least 6 tests", "file X exists". A criterion must pin the observable behaviour that artifact exists to demonstrate. A suite-wide floor is permitted only under property 4.
2. **Every grounding claim carries provenance** (A2). Every claim in the epistemic map is tagged **source-read** or **sample-inferred**. Reject an untagged claim, and reject any sample-inferred claim that sets a comparison tolerance or mandates a mechanism — an inferred claim reaches the executor as contestable guidance only.
3. **Every criterion states a proof standard** (A5). Reject a criterion that names no proof standard, and reject an evidence-obligations section that offers format freedom without stating the three properties the proof must have (discriminating, attributed, per-criterion). Format is the executor's choice; the properties are not.
4. **Any absolute suite floor is checked satisfiable** (A4). If a criterion states a suite-wide floor, the brief must show the arithmetic against the launch baseline. An unchecked floor is forbidden — a halt-bound run that was halt-bound from the moment it began is the failure this catches.
5. **No reading under which the criteria all pass and no work happens** (#957 D2). Ask, verbatim: *"Is there a reading of the criteria under which every one passes and no work happens?"* **Answering is an act of construction, not of assertion.** Name the candidate reading — the specific way each criterion could be satisfied by the tree as it already stands, or by the cheapest edit that changes nothing observable — and then either name the criterion that blocks that reading, quoting the clause doing the blocking, or fail the brief. A bare "no" with no constructed reading does **not** discharge this property; an unconstructed answer is itself a nonconforming answer, because it is exactly what a reviewer who never looked would also write. This is the catch the doctrine's own record says goes uncaught: "Both trial runs shipped tests that could not fail" (`Documents/Design/chunked-delivery.md` § How a chunk plan specifies, A3). Property 5 is the conformance-check half of the vacuity question; its adversarial half is the required vacuity question in the convergence cold read (`skills/design-exploration/SKILL.md` § Convergence Filter).

The check is a reviewer and author activity, not a validator branch: properties 1 and 3 need a reading of what a criterion *means*, property 4 needs a number the text does not contain, and property 5 needs a reading of what the criteria mean *together* — the strongest member of that class, since no single criterion's text can settle it. Do not infer that a brief passing `Invoke-FVPlanValidate` has passed this check — structural validation says the shape is present, and says nothing about whether what is written in it conforms.

#### The routing call as a review target

Beat 2 of the open-for-work flow classifies an issue **routine** or **novel** against its still-open list (`Documents/Design/open-for-work.md` § Beat 2 — evaluate which path follows). On the routine arm that verdict and its falsifier ride the brief itself, which is what makes it reviewable at all; that document's § Review names it a review target, and this is the charter surface that aims at it. Run it alongside the conformance check as part of the reviewer's first act, and record the outcome in the persisted `**Plan Stress-Test**` summary — the same surface the cold read's vacuity sentence lands on (§ Brief-review emission).

**Which arm applies is decided by the brief's authority source** (§ Brief plan variant), and every emission names the evidence for that classification, so a misclassified source leaves an auditable trace instead of passing silently. Stated exactly, because the difference matters: **naming is not verifying**. Nothing at this step re-derives the parent link or re-reads the framing record, so a deliberately false classification is not caught here — what the named evidence buys is that a later reader can check it.

**Source (b) — a standalone issue carrying an affirmed open-for-work framing record.** Locate the recorded routing verdict. It may ride **anywhere in the brief**: the six-section contract deliberately has no dedicated slot for it, so absence from any particular section is not absence from the brief. Then re-ask beat 2's own question over the brief's `## 2. Epistemic map` known-unknown entries — *could this unknown change what we affirmed we are building, or change how we would know it is done?* — and rule one of **four** ways. Read what the verdict *says*, not only that one is there:

- **Present, routine, and consistent with the map** — every known-unknown the brief still carries is one the run itself can settle. Record the target as checked and consistent, naming the entries read.
- **Present, routine, but inconsistent with the map** — at least one known-unknown could void a criterion or the chunk boundary, so the routine verdict does not survive the brief's own map. This is a **finding**: the brief is being written where the flow's own rule routes to design.
- **Present but novel** — a novel verdict authorizes no brief at all: on that arm the conversation continues into design and the verdict rides the `design-phase-complete` marker (`open-for-work.md` § The two outputs). A brief carrying a recorded novel verdict is the same lawfulness failure as one carrying none, and is ruled the same way.
- **Absent** — the brief is **not lawful under source (b)**. #957 Amendment 10 is explicit that a framing record with beat 2 unrun does not authorize a brief, so a source-(b) brief carrying no routing verdict is a **review failure**, said so plainly, not a gap noted in passing.

**What "review failure" means here, stated rather than left to inference.** Like a failed conformance-check property, it is corrected before the brief is dispatched or run — not argued about after. And stated honestly, because the alternative is an overclaim: **nothing mechanical enforces that.** This charter has no veto — the `design-challenge` shape is prosecution-only and non-blocking by design (`skills/adversarial-review/adapters/design-challenge.md`), and a brief review's only disposition vocabulary is `incorporate | dismiss | escalate`, `dismiss` included. What the charter can require is that the outcome be recorded *as a failure* rather than as a note, so that shipping an unlawful brief is a visible, attributable choice instead of a silence. Giving the verdict a blocking consumer would be new gate machinery this charter does not own.

**Source (a) — a chunk sub-issue of a designed parent.** Record the target as **not applicable, with its basis stated**: this brief **carries no routing verdict of its own**. Do not write "no beat 2 ran" — that is false for a chunk of a parent designed on the open-for-work novel arm, where beat 2 did run and its verdict rides the parent's `design-phase-complete` marker (`open-for-work.md` § The two outputs). The basis also names the evidence for the source classification itself — the parent link for source (a), the framing record plus its verdict for source (b) — since an n/a is only as sound as the classification that selected it.

The n/a arm is an **emission, not a skip**. A review that says nothing about the routing call is indistinguishable from one that never looked — the same defect the required vacuity sentence exists to remove on the cold-read side.

**Scope, stated so it is not over-read.** This charter reviews briefs. On the novel arm the routing verdict rides the `design-phase-complete` marker instead, and no review surface currently names *that* a target; the gap is recorded on #957 and is not closed here. Do not read this section as saying the routing call is reviewed wherever it is recorded.

### Criteria Lenses

> **Authoritative source**: which lessons are promoted here, what anchor each one lives at, and the trigger text that has to reach a reader are recorded in `Documents/Planning/lesson-promotion-manifest.json`. `.github/scripts/Tests/lesson-promotion-manifest.Tests.ps1` is what stops this section and that manifest drifting apart, and it is the suite a red comes from. **Renaming a heading below is a migration, not a regression** — update that lesson's `anchor` in the manifest in the same commit as the rename. A red naming an anchor you just renamed is reporting a manifest row left behind, not a lost lens.

**Line budget, stated out loud because this file is already past the 500-line structural limit.** This section is held to **40 lines and 8,000 characters** — the second bound matters more, since `MD013` is off here and a line count alone is satisfiable by appending forever. It is seven lenses with no worked examples: each one's incident detail lives in [references/criteria-exhibits.md](references/criteria-exhibits.md), and that split is what let two lenses arrive without the budget moving. Adding an eighth by *appending prose here* rather than by extracting is the drift this note makes visible. The composite-structure suite that would enforce it was quarantined when this note was written and now runs in CI (#1035 measured it, #1036 promoted it) — but read what it actually asserts before treating it as the gate: its skill set is a closed literal, so it reports a constant rather than a signal about this budget. Until something checks the budget itself, this stays a figure a reader holds an author to.

Seven ways a criteria set passes review and still fails to force the work — each a defect the conformance check above did not catch.

#### Criteria can pin the reader-facing surface completely and miss every programmatic consumer

A criteria set can pin everything a *maintainer reads* from an artifact and leave every *programmatic* consumer free, so the work is satisfiable by putting the feature somewhere no real caller executes. A clause constraining **how the invoker invokes** does not constrain **where the code lives**. **Enumerate the callers before writing the criteria**, then add a criterion in the form *"X is a property of doing the work, not of the entry point used to start it"*, proved by exercising both paths at one commit. Prose steering toward the right implementation is not a pin — and a falsifier is explicitly prose the run is not graded on (A3), so it cannot carry this either. Exhibit: [references/criteria-exhibits.md](references/criteria-exhibits.md) § Five criteria that a gate script satisfied.

#### One noun naming two things lets a compliant run satisfy every criterion and do nothing

When one noun in a plan names two referents, a literal reading picks whichever makes the work smallest, records an empty result, and satisfies several criteria while the enumeration the plan exists to force never happens. The two meanings are usually distinct in the design and collapse in the design-to-brief rewrite: prose reads unambiguously to an author holding both referents in mind, and an unattended executor holds only the text. **When a plan names two instants, two trees, or two commits, give them different nouns and state the distinction once, up front, before either is used.** Exhibit: [references/criteria-exhibits.md](references/criteria-exhibits.md) § One noun, two commits, eight days apart.

#### A vacuity answer can name the right verdict and cite blockers the executor can escape

Property 5 demands a constructed candidate reading plus the clause that blocks it. Constructing the reading is not enough: **the named blocker must itself be unescapable**. A blocking clause whose binding depends on something the run chooses — a corpus the run sweeps, a window its own invocation time sets — blocks nothing, and the verdict then survives on a clause never cited, so the recorded justification is weaker than it claims. For each clause you name as blocking, ask **who controls whether this clause binds — the tree, or the run?** Prefer clauses pinned by evidence already in the brief. Exhibit: [references/criteria-exhibits.md](references/criteria-exhibits.md) § Two blockers the executor controlled.

#### A proof standard can name every polarity and still miss the population none of its exhibits exercises

A polarity list enumerates *outcomes*; it does not enumerate the shapes of thing the procedure has to **read** to reach one. A criterion can name every polarity, pass all of them, and still be blind to the live population whose artifacts omit an optional field the procedure derives its search set from. **List every field the procedure reads, open the writer that produces those fields, ask which are optional, then count the live population that omits each.** Two corollaries: collapsing distinct negative outcomes ("couldn't read it", "nothing to search", "no record exists") makes a detector a false-alarm generator; and a new contract inherits an era, so it needs interpretation guidance for pre-contract artifacts — never a domain exclusion, since the exhibit it was written around must still fail. Exhibit: [references/criteria-exhibits.md](references/criteria-exhibits.md) § Four polarities over an unexercised population.

#### Specify at the knowledge level you actually have

Already binding as chunked-delivery amendment **A1** and enforced by conformance property 2 above — read the rule there. What this lens adds is the shape to watch for: when a task's central unknown is a *discoverable external fact*, a pre-discovery spec that hard-codes the hypothesised answer is **structurally blind to the exact premise that is false**, and can score a wrong implementation above a source-verified one. Prefer resolution-shaped checks ("the derived value resolves against the real world-state") over expectation-shaped ones descending from a hypothesis, and escalate primary evidence contradicting a locked premise mid-run as a spec gap. Exhibit: [references/criteria-exhibits.md](references/criteria-exhibits.md) § A premise encoded into a comparison operator.

#### A source-read tag certifies that you looked, not that you looked where the answer lives

Before applying `source-read`, ask of the **instrument**, not the claim: *could this search have returned a different answer if the claim were false?* If the thing claimed lives somewhere the search never touched, the tag is a citation, not evidence. Three axes recur, each defeating a differently-shaped grep: **scope** — several authoritative registers here are *issue-body content*, reachable only through `gh api … --jq .body`, and amended while you write, so never hardcode a number read from one; **vocabulary and case** — hand-picked terms that all return zero, or a case-sensitive search over a term capitalised elsewhere; and **string-presence standing in for behaviour**. When a search returns exactly the number that makes your claim work, **widen it once on purpose** — drop the qualifiers, the case, the path filter. Exhibit: [references/criteria-exhibits.md](references/criteria-exhibits.md) § Six scope failures under one tag.

#### Establish which executor lane actually failed before moving an instruction to reach it

A "the instruction is in the wrong place" diagnosis silently assumes **which reader** was supposed to meet it, and that is testable from artifacts already in hand: a lane mandates fields in its own output, so counting those mandated fields across the failing runs' artifacts says whether the lane was ever used. **Count the lanes before picking a home** — when no agent body reaches the population, the home has to be an artifact the run itself carries. **An establishable fact must not be deferred to a falsifier**: tagging "did those runs read this file?" as inferred defers something answerable that minute — the specify-at-your-knowledge-level failure in another hat. And when a relocation's *other* objections — anchor ordering, a size ceiling — evaporate once the home changes, they were symptoms of the wrong home. Exhibit: [references/criteria-exhibits.md](references/criteria-exhibits.md) § A home chosen for a lane the failures never used.

### Adapter and executor selection

#### Executor field semantics

Frame slices may include optional `executor:`. Legal values use the exact enum literal `agents/*.agent.md path | inline`. `agents/*.agent.md` paths dispatch that agent's paired shell; `inline` keeps the resolved adapter methodology in the active conductor context. `executor: none` is deferred and must not be emitted by current plans.

When `executor:` is absent, derive the default from the adapter frontmatter's `adapter-type:` enum literal `work | predicate`: `work` defaults to `agents/Senior-Engineer.agent.md`, while `predicate` defaults to `inline`.

#### Planner glob workflow

Run `Glob skills/*/adapters/*.md` to discover all adapter candidates for a port; distinguish adapter roles by `adapter-type:` frontmatter and filename shape:

- **`adapter-type: work`, filename ends in `-adapter.md`** — single-variant work adapter. Read the candidate's `## When to use` and pick the one whose guidance matches the slice.
- **No `adapter-type:` frontmatter, filename does NOT end in `-adapter.md`** — multi-variant selector-named work adapter (e.g., `standard.md`, `lite.md`, `judge-only.md`, `proxy-github.md`, `ce-gate-api.md`). Select the correct variant via its `applies-when:` predicate.
- **`adapter-type: predicate`** — the filename suffix encodes the variant: `-auto-na-adapter.md` for not-applicable, `-explicit-skip-adapter.md` for manual skip. Select by port token and variant suffix.

Do not infer methodology from a skill directory when no adapter file matches. Either select an explicit adapter path or document why the plan remains legacy/non-runner for that slice.

#### Cycle and terminal interaction

`executor:` controls only how the selected adapter is invoked. It does not change existing cycle or terminal token semantics: keep `sN[#cycle:N][#terminal]` in the spine, `cycle: N` and `terminal: true` in slice metadata, and terminal credit responsibility on the last terminal slice for the port.

### Execution mode selection

Provenance: this heuristic is absorbed from Code-Conductor's prior execution-mode policy for issue #589; plan authors own selection while runtime agents consume the declared mode.

For each implementation step, make a per-step declaration: declare the execution mode in the visible plan step for human readers and in the frame-spine `slices.sN.execution_mode` entry as the authoritative machine-readable location. Do not add `execution_mode` to per-step `frame-slice` blocks. Keep the requirement contract and convergence gates identical for serial and parallel work; the mode changes coordination style, not the acceptance bar.

Prefer `parallel` when the acceptance criteria are stable, the step is isolated with low coupling, clear interfaces exist between the implementation and test work, and fast implementation-plus-test feedback is valuable.

Prefer `serial` when the acceptance criteria are exploratory or ambiguous, test-first clarification is needed before implementation should proceed, or refactor and dependency risk is high.

Quick checklist before declaring mode for a step:

- Stable AC + low coupling + clear interfaces -> `Execution Mode: parallel`
- Ambiguous AC or high-risk refactor/dependencies -> `Execution Mode: serial`

### Plan-markdown template

The plan comment carries prose, the `frame-spine` block, and both sibling pointers. It no longer carries `frame-slice`, `phase-containment`, or `judge-rulings` blocks (863-D1):

```markdown
---
spine-omitted: { omit unless plan-too-small }
---

## Plan: {Title (2-10 words)}

{TL;DR - what, how, why. Reference key decisions. (30-200 words)}

<!-- frame-spine
spine_schema_version: 2
generated_at: {ISO-8601 UTC}
coverage: complete
slice_comment_id: { frame-slices-{ID} sibling comment id, set at persist time }
ports:
  {port}: [sN, sM#cycle:2#terminal]
slices:
  sN:
    execution_mode: {serial | parallel}
    rc: {GREEN code/test action summary}
    ac_refs: [AC#]
    depends_on: []
    cycle: 1
-->

**Steps**

1. {Action with file path links and `symbol` refs}
   - Execution Mode: {serial | parallel}
   - Requirement Contract: acceptance-criteria slice; invariants/edge cases; non-goals.
2. {Next step}
   - Execution Mode: {serial | parallel}
   - Requirement Contract: ...

**Verification**
{How to test: commands, tests, manual checks}

<!-- verification-evidence -->

**Verification Evidence**

- **AC{N}** ({category: text-presence | structure-presence | downstream-consumer | numeric-or-structural | named-standard}): {verification action and result}. **{disposition: verified | revised | exempted | planned}** - evidence: {grep/read command with path:line, consumer path/function, numeric or structural source, or named-standard reference}. {Required for revised/exempted: rationale. Required for planned: slice anchor s{N} and category the future artifact will satisfy.}

**Decisions** (if applicable)

- {Decision: chose X over Y}

**Plan Stress-Test** (summary of Code-Critic review via `skills/adversarial-review/platforms/claude.md` `{adapter: standard | design-challenge}` adapter — name the one actually selected per `## Stress-Test Preparation` step 1)

- Challenge: {finding} - Prosecution: {pass/source summary} - Post-judge ruling: {sustained|defense-sustained|judge-rejected/user-confirmed} - Maintainer disposition: {incorporate|dismiss|escalate}
- Overall confidence: {high | medium | low} - {one-sentence rationale}
```

The `<!-- plan-issue-{ID} -->` marker itself (added at persist time, not part of the drafted body above) is immediately followed by the `<!-- phase-containment-ledger-ref: {comment_id} -->` pointer (863-D11) once the ledger sibling exists.

Each implementation step is still drafted with its per-step `<!-- frame-slice ... -->` block during `## Draft Workflow` (see `### Spine and Slice Discipline`), but at persist time that block is posted into the `<!-- frame-slices-{ID} -->` sibling comment, never inline in a plan-comment step:

```markdown
<!-- frame-slices-{ID} -->
<!-- frame-slices-generated-at: {same ISO-8601 UTC value as the spine's generated_at} -->

<!-- frame-slice
id: s1
provides: [{port}]
adapter: {path}
migration-scan: {true — migration-type slice #1 only, omit otherwise}
depends-on: []
ac-refs: [AC#]
-->
<!-- frame-slice
id: s2
provides: [{port}]
adapter: {path}
depends-on: [s1]
ac-refs: [AC#]
-->
```

The phase-containment blocks (`### Phase-containment emission` above) and the machine-readable `judge-rulings` block (`### Judge-rulings machine block (811-D1, co-moved by 863-D4)` above) are posted into the `<!-- phase-containment-ledger-{ID} -->` sibling comment, co-located together (863-D4). The two block families are intentionally different shapes and are not interchangeable: `judge-rulings` stays **bare** — a single unclosed `<!-- judge-rulings ... -->` comment, per rule 3 above — while `phase-containment` is **paired** — a self-closed `<!-- phase-containment-{ID} -->` open tag followed by plain-text YAML fields and a separate `<!-- /phase-containment-{ID} -->` close tag — because the close tag is what powers `Get-PhaseContainmentBlock`'s pair-matching malformation detection (issue #772 D6: an open tag with no matching close tag is skipped as an unclosed, malformed block rather than silently absorbing whatever text follows it). A fully literal worked example, with `{ID}`, `{issue}`, `{marker}`, and `{finding_id}` left as the only placeholders:

```markdown
<!-- phase-containment-ledger-{ID} -->

<!-- phase-containment-{ID} -->
finding_key: plan-stress-test:{issue}:{marker}:{finding_id}
introduced_phase: design
catchable_phase: plan
caught_stage: plan-stress-test
escape_distance: 0
severity: medium
systemic_fix_type: instruction
category: pattern
apparatus_meta: false
appended_at: 2026-07-18T22:20:00Z
<!-- /phase-containment-{ID} -->

<!-- judge-rulings
- finding_id: {finding_id}
  judge_ruling: {sustained | defense-sustained}
-->
```

The `<!-- judge-rulings` block above is the machine-readable counterpart to the plan comment's prose bullets: one entry per merged finding_id, projected per `### Judge-rulings machine block (811-D1, co-moved by 863-D4)`. When the merged stress-test produces zero findings, emit the pinned placeholder instead: `- finding_id: none` / `judge_ruling: defense-sustained`.

### Base rules

- No code blocks for implementation details - describe changes, link to files and symbols. Frame-spine and frame-slice metadata comments are the routing exception.
- No questions at the end - ask during the workflow.
- Include execution metadata (mode + requirement contract expectations) so implementers can execute without re-deriving process rules.
- Treat the frame spine and slices as required plan output, not optional documentation, whenever the D8 size threshold is met.
- When a step crosses a layer boundary (as defined in `.github/architecture-rules.md`), note the dependency direction and verify it aligns with documented architecture rules. Scope steps to a single layer where feasible.
- Insert a dedicated **`[CE GATE]`** numbered step as the final implementation step after the Code-Critic review step (and after all accepted Code-Critic findings are resolved). Format: `N. [CE GATE] - Surface: {type} - Design Intent: {link or one-line summary} - Scenarios: {functional + intent} - Method: {how each scenario is exercised}`. When BDD is enabled, list each scenario by concrete ID with classification, e.g., `S1: {description} [auto/manual]` or placeholder `S{N}: {description} [auto/manual]`. The `[CE GATE]` step is blocking - advancement past it requires either completion or the documented skip marker.
- When `ce_gate: false`, omit the CE Gate step and state the no-customer-facing-surface rationale.
- For backend/non-UI/CLI projects, the CE Gate surface is the API or CLI - identify appropriate scenarios for customer-perspective verification.
- Keep the plan scannable.

### Specialized rules

- **Agent-file insertion strategies** — when a step modifies `.agent.md` files, categorize each file as exactly one of: (a) **clean insert** — no existing identity/personality text at the canonical insertion point (top of body, immediately before the main heading); (b) **fragment replacement** — existing identity/personality text is present at the canonical insertion point; (c) **stance-preserving insert** — a named stance section sits at the insertion point and must be preserved. Behavioral guidance found elsewhere in the body (not at the canonical insertion point) does not qualify as a fragment — classify those files as clean inserts.

#### Migration-type issues

Issues involving pattern replacement, API migration, rename/move across files, or signal phrases like "replace X with Y", "migrate from A to B", "rename Z across the codebase", or "remove all references to W" require that **Step 1 of the plan MUST be an exhaustive repo scan**. The scan produces the authoritative list of files to update; the issue author's file list must not be relied on as complete. Subsequent steps must be scoped to scan-discovered files only — additions require a documented reason.

**Authoring-time contract for `migration-scan: true`**

When authoring a migration-type plan with three or more implementation steps (spine-bearing plan), the plan author MUST:

1. Add `migration-scan: true` to the `<!-- frame-slice -->` comment block for slice #1 (the exhaustive-scan step). This block is posted into the `<!-- frame-slices-{ID} -->` sibling comment at persist time (863-D1), same as every other frame-slice block — the placement rule below governs positioning *within* the block, not which comment holds it. Example:

   ```text
   <!-- frame-slice
   id: s1
   provides: [implement-docs]
   adapter: {path}
   migration-scan: true
   depends-on: []
   ac-refs: [AC#]
   -->
   ```

2. **Placement constraint**: `migration-scan: true` belongs in the `<!-- frame-slice -->` HTML comment block only. Do NOT place it in the machine-readable spine `slices:` block — the spine key parser rejects hyphenated keys and would null the entire spine.
3. **Port constraint**: slice #1 must use a real, deterministic `provides:` port (e.g., `implement-docs`). Using `coverage: exploratory` on a migration scan slice is disallowed — the scan is a deterministic deliverable, not exploratory work.

Slice #1 frame-slice example (keys sit at column 0 inside the comment block; the parser rejects indented keys):

```text
<!-- frame-slice
id: s1
provides: [implement-docs]
adapter: {path}
migration-scan: true
depends-on: []
ac-refs: [AC#]
-->
```

For **legacy/spine-omitted plans** (fewer than three implementation steps and `spine-omitted: plan-too-small`), the `migration-scan: true` slice marker does not apply. Instead, the plan's Step 1 prose MUST be the exhaustive repo scan. The authoring-time validator checks the first-step text for a scan action when no spine is present.

Non-migration plans have no `migration-scan` marker and no validation friction from this rule.

- **Removal steps** — when a step removes a concept, feature, section, or phrase from a file, the Requirement Contract must include a completeness validation grep confirming zero remaining references in the target file and any other files that referenced it.
- **Cross-file constants** — when a step (a) implements or modifies a script or module that consumes enumerated values produced by another file (stage names, category strings, enum labels), or (b) creates or modifies a file that authoritatively defines enumerated values consumed by scripts, the Requirement Contract must: (i) for case (a) name the authoritative source file; for case (b) identify all known consumer scripts via grep — and (ii) list the exact allowed values as a quoted string enum (example format: `Allowed values: 'main' | 'postfix' | 'ce'`).
- **Multi-tier statistical output** — when a step involves a statistical output schema with multiple independent sub-sections (calibration scripts, metrics aggregators), the Requirement Contract must enumerate each output section that requires a `sufficient_data` gate rather than describing gating as a single aggregate requirement.
- **CE Gate multi-path output coverage** — when a script emits a new output block in more than one conditional path, require at least one CE Gate scenario for each path where the block appears. Each scenario's acceptance criterion must specify the expected behavior of every consuming agent in that path, not merely output format.
- **New-section ordering** — when a step creates a new section with multiple sub-items (subsections, list items, blocks), list them in the intended reading/document order and annotate "add in this order" so placement is deterministic.
- **Security-sensitive field carve-out** — when a step defers conflict resolution for a data migration, the Requirement Contract must enumerate security-sensitive fields (auth hashes, tokens, permission flags) and specify their merge semantics separately from data fields. If no security-sensitive fields exist, state that explicitly.

### Agent-capability verification

When any plan step characterizes another agent's capabilities, permissions, or scope, verify the claim against that agent's own specification (read the agent's `.agent.md` file) before finalizing the requirement contract.

## Plan Approval Prompt Format

When asking for plan approval, treat the approval prompt as a decision-card-first consent surface. The approval dialog must stand on its own so the user can approve from the dialog alone without depending on the transcript or conversation history.

The approval prompt must include a mandatory approval card in this compact labeled shape:

- `Change:` one sentence describing the planned behavior or workflow change in user-relevant terms.
- `No change:` one sentence naming the meaningful boundary, exclusion, or non-goal the user might otherwise assume is included.
- `Trade-off:` the main compromise, watchpoint, or cost the user is accepting.
- `Areas:` the affected files, workflow areas, or systems at a glance.

`Execution:` is conditional. Include it only when execution shape materially affects approval — for example, plans with more than three steps, plans using parallel execution lanes, or cases where sequencing itself is likely to change the approval decision. When present, summarize the plan shape rather than restating every step.

Prefer exact files only when there are a few high-signal paths. When exact files are noisy, collapse to grouped areas or area-level summaries instead of a raw file dump. If exclusions are implicit, derive `No change` from the plan boundary, non-goals, or unaffected surfaces. If `Change` or `No change` still cannot be stated concretely after those fallbacks, stop and clarify before asking for approval.

Present the plan as a **DRAFT**, then immediately ask for approval in the same turn. Never end a turn after presenting a draft without asking for approval — this wastes a user turn just to say "looks good."

The approval prompt must offer an explicit approval option and an explicit reject/non-approval option using `Reject` or equivalent wording.

<!-- plan-authoring-non-overridability:begin -->

### Rule: Non-overridability

The plan-approval question is unconditional with respect to user pacing or auto-mode directives. Pacing directives apply to preference-clarifying pauses, not to plan-approval methodology checkpoints. The user's lever to skip plan approval is to select the documented `Reject` or equivalent option in the approval prompt, not to issue a pacing directive that suppresses the prompt entirely.

<!-- plan-authoring-non-overridability:end -->

## Context Management

If discovery becomes long or tool-heavy, compact before drafting. Preserve the key decisions, rejected alternatives, acceptance criteria, open questions, and CE Gate assessment so the plan draft starts from stable context instead of a partially remembered transcript.

## Related Guidance

- Load `research-methodology` when the main challenge is evidence gathering rather than plan structure
- Load `bdd-scenarios` when scenario IDs and classification are required for the CE Gate step
- Load `implementation-discipline` once the work shifts from planning to code changes

## Gotchas

| Trigger                                             | Gotcha                                                                 | Fix                                                                   |
| --------------------------------------------------- | ---------------------------------------------------------------------- | --------------------------------------------------------------------- |
| Discovery starts writing implementation steps early | The plan inherits assumptions before feasibility and scope are checked | Keep discovery read-only and delay the full plan until alignment ends |

| Trigger                                               | Gotcha                                                                     | Fix                                                                          |
| ----------------------------------------------------- | -------------------------------------------------------------------------- | ---------------------------------------------------------------------------- |
| CE Gate is drafted from mechanics instead of outcomes | The plan exercises the surface but misses design intent and customer value | Reuse Experience-Owner scenarios when present, or derive both scenario types |

## Frame Ports Filled By This Skill

| Port   | Work adapter                                                         | Auto-N/A adapter                                                     | Explicit-skip adapter                                                            |
| ------ | -------------------------------------------------------------------- | -------------------------------------------------------------------- | -------------------------------------------------------------------------------- |
| `plan` | [agents/Issue-Planner.agent.md](../../agents/Issue-Planner.agent.md) | [adapters/plan-auto-na-adapter.md](adapters/plan-auto-na-adapter.md) | [adapters/plan-explicit-skip-adapter.md](adapters/plan-explicit-skip-adapter.md) |
