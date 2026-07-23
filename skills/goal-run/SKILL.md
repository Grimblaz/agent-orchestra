---
name: goal-run
description: "Methodology home for the goal-run harness (issue #874): the stage-machine contract, halt-reason precedence, launch arms, worktree lifecycle, the label-to-ledger join query for escape-rate segmentation, and the untrusted-content discipline for a single vendor-goal-loop harness run. Use when extending, halting, resuming, or documenting a /goal-run invocation, or when writing the escape-rate query that segments goal-run PRs from Code-Conductor-orchestrated PRs. DO NOT USE FOR: the live /goal-run execution prose itself (use agents/Goal-Run.agent.md, the shared body this skill is referenced from) or the goal-contract plan-authoring schema (use skills/plan-authoring's goal-contract schema, decision 872-D2)."
---

<!-- markdownlint-disable-file MD041 MD003 -->

# Goal-Run Harness

Reference methodology for the goal-run harness: a launcher/resumer that walks a single GitHub issue's approved goal-contract (a structured, machine-checkable target the vendor's own `/goal` loop runs against) through to a reviewed, classed pull request, without a human answering `AskUserQuestion` prompts mid-run. This file documents the mechanics; the runnable prose lives in [agents/Goal-Run.agent.md](../../agents/Goal-Run.agent.md).

## When to Use

- When extending, debugging, or reviewing a change to the goal-run harness's stage machine, halt model, worktree lifecycle, or untrusted-content barriers.
- When writing or reviewing the `agents/Goal-Run.agent.md` / `agents/goal-run.md` shared body and shell, or the customer-experience (CE) surface-class doc ([skills/customer-experience/references/goal-run-surface-classes.md](../customer-experience/references/goal-run-surface-classes.md), 874-D8) and dual-flow guide that reference this skill.
- When building the escape-rate segmentation query described in `## Label-To-Ledger Join`.
- When a reader needs to know what a `goal-run-stage-{issue}`, `goal-run-inflight-{issue}`, or `goal-halt-report-{issue}` marker means.

### DO NOT USE FOR

- **Running `/goal-run` itself** — that is `agents/Goal-Run.agent.md` (shared body) and `agents/goal-run.md` (Claude Code shell). This skill is the reference the body cites, not a substitute for it.
- **The goal-contract's own shape** (targets, halt conditions, evidence obligations) — that schema lives under `skills/plan-authoring/schemas/goal-contract.schema.json` (872-D2).
- **General adversarial-review, CE Gate (Customer Experience Gate — the validation step confirming an implementation achieves the intended customer experience), or PR-persistence mechanics** — the Post-Loop Chain (below) reuses `adversarial-review`, `customer-experience`, and `persist-changes` unchanged; load those skills directly for their own methodology.

## Purpose

A goal-run invocation must survive a crash or a second concurrent launch attempt without losing track of where it is or double-provisioning a worktree. Every stage transition, halt, and terminal check is therefore read from durable GitHub artifacts — never from what a conversation remembers saying — and every function that makes one of these decisions is a tested PowerShell primitive under `.github/scripts/lib/goal-run-*-core.ps1`, not inline arithmetic in the agent prose.

## Stage-Machine Contract

The stage-machine's top-level vocabulary is a fixed four-value sequence (`$script:GoalRunStageOrder` in [goal-run-stage-core.ps1](../../.github/scripts/lib/goal-run-stage-core.ps1)):

`pre-loop -> loop-launched -> loop-released -> chain-dispatched`

`pre-loop` is the implicit starting state — no marker is ever posted for it on its own. A single `<!-- goal-run-stage-{issue} -->` issue comment is upserted in place (never appended-to) and always reflects the latest completed stage. This is deliberately the coarse top-level enum a resumed invocation switches on; finer-grained per-attempt history (why a run deviated, what it checkpointed) lives in the typed run log and the mutex marker, not here.

`Resolve-GoalRunResumeStage` decides where a resumed invocation re-enters, in this precedence (highest wins):

1. Contract hash not verified against the launch-pinned value -> `blocked` (not a stage to execute — report and stop; the contract needs plan-side remediation).
2. Terminal emissions already verified on a known PR -> `complete` (nothing left to do).
3. An explicit stage marker is present -> resume from the stage it names.
4. No explicit marker, but the typed run log has a `checkpoint`/`deviation`/`experience-observation` entry -> the loop ran even without an explicit marker write (e.g. a crash between launch and the next marker).
5. `goal-run-active.json` exists but no run-log evidence -> the worktree was provisioned but the loop was never launched.
6. A mutex marker exists but nothing else -> crash mid `pre-loop`.
7. Nothing present -> fresh launch.

`blocked` and `complete` are terminal reports, not stages a resumer executes.

## Halt Model And Precedence

A halt report is a closed, five-value-enum object validated against [`skills/goal-run/schemas/goal-halt-report.schema.json`](schemas/goal-halt-report.schema.json) (`additionalProperties: false` — every field the harness or an executor can populate is named and typed). The `halt_reason` enum is reused verbatim from the goal-contract schema's `halt_conditions` (872-D2): `unachievable-target`, `invariant-conflict`, `budget-exhausted`, `gate-input-needed`, `chain-stage-failure`.

When more than one halt condition is true at the same evaluation point, `Resolve-GoalRunHaltPrecedence` ([goal-run-chain-core.ps1](../../.github/scripts/lib/goal-run-chain-core.ps1)) picks the single winner by this **total, non-negotiable** order (highest wins):

`invariant-conflict > unachievable-target > gate-input-needed > budget-exhausted > chain-stage-failure`

This ordered list is the entire precedence rule; nothing else in the file overrides it. `Resolve-GoalRunHaltPrecedence` does not itself decide *whether* a condition is true — each producer's own detection lives elsewhere (the launch-pinned contract-hash mismatch and an executor's own halt-claim for `invariant-conflict`; the re-validation disposition, the fix-cycle cap, or a stage crash for `chain-stage-failure`; the wall-clock backstop for `budget-exhausted`; the chain-gate demand for `gate-input-needed`) — callers pass in the already-decided booleans.

A single-condition halt (nothing else co-occurring, e.g. the loop-released bounded-retry exhaustion) skips `Resolve-GoalRunHaltPrecedence` entirely and goes straight to the report builder — the precedence function only matters when two or more producers are simultaneously true.

Never hand-build a halt comment. `New-GoalRunChainHaltReport` composes the schema-shaped object (running every free-text field through secret redaction, below); `Invoke-GoalRunHaltEmit` ([goal-run-halt-core.ps1](../../.github/scripts/lib/goal-run-halt-core.ps1)) schema-validates and refuses to post an invalid report.

## Launch Arms

### Arm I (in-session) — the only arm implemented in this PR

`/goal-run {issue}` is both launcher and resumer. The harness verifies the contract hash, posts a mutex marker (`goal-run-inflight-{issue}`) *before* provisioning any worktree so a running worktree with no live marker can never exist, tiebreaks a concurrent launch race by lowest comment id, then sets the goal on itself and becomes the executor inside the freshly provisioned worktree. When the vendor `/goal` loop completes and control genuinely returns to the harness session, it reads the now-flushed `goal_status` verdict and enters the Post-Loop Chain (re-validate, CE Gate, adversarial review, capped fix cycles, PR creation with classing — see [agents/Goal-Run.agent.md](../../agents/Goal-Run.agent.md) `## Post-Loop Chain` for the full stage-by-stage prose).

The loop-to-chain seam is deliberately built from durable artifacts only: `New-GoalRunExecutorSessionHandle` and `Invoke-GoalRunLaunchChain` take an issue number, repo root, contract hash, worktree path, and a session handle — never live conversation context — so a future arm can populate the same shapes without rewriting this transition.

### Arm H (headless) — PR-2, not yet implemented

A future PR will let the harness supervise an externally polled `claude -p` process instead of running in-session. The loop-to-chain seam above is already shaped to accept this without a rewrite. No further design decisions have been made yet; do not invent Arm H behavior beyond this pointer.

### Arm M (manual hand-off) — PR-2, not yet implemented

A future PR will define a manual two-block rendering surface for a human to hand off a run. This PR renders no Arm M output and accepts no `scope_boundaries` prompt field. No further design decisions have been made yet; do not invent Arm M behavior beyond this pointer.

## Worktree Lifecycle

All worktree mechanics live in [goal-run-worktree-core.ps1](../../.github/scripts/lib/goal-run-worktree-core.ps1); its own header comment is the authoritative function-by-function summary — this section is a pointer, not a re-derivation.

- **Provision** — `New-GoalRunWorktree` refuses a dirty tree first, then creates a named branch `goal-run/issue-{N}-{token}` (`{token}` is a GUID-style collision-proof suffix, so two concurrent runs for the same issue never collide) at a short root outside the checkout, setting `core.longpaths` at `worktree add`.
- **State file** — `New-GoalRunActiveState` writes `goal-run-active.json` at the worktree root: ceilings, baseline, arm, executor session id, the launch-pinned `contract_hash`, `launched_at`, a `heartbeat_at` timestamp (seeded equal to `launched_at`), and `teardown_deferred` (default `false`). `Get-GoalRunActiveState` reads it back and returns `$null` on a missing file rather than throwing. `Update-GoalRunActiveStateHeartbeat` refreshes `heartbeat_at`.
- **Teardown** — `Remove-GoalRunWorktree` retries `git worktree remove` with backoff on every exit path and diagnoses the outcome honestly across the same six-value vocabulary used by the session-startup cleanup detector: `removed`, `removed-partial-root-held`, `removed-partial-content-remains`, `stale-registration`, `failed`, `verification-indeterminate`. On retry exhaustion it sets `teardown_deferred: true` on the state file (best-effort) rather than throwing. It never force-removes a locked worktree on a `prunable` porcelain flag alone — only on `Test-Path`-verified absence of the directory, because real git never sets `prunable` on a locked worktree.

## Label-To-Ledger Join (874-D7)

Every goal-run PR carries two machine-readable markers of its own provenance, both written at PR-creation time by `Invoke-GoalRunClassEmission` ([goal-run-chain-core.ps1](../../.github/scripts/lib/goal-run-chain-core.ps1)):

- The `goal-run` GitHub PR label, applied by `Add-GoalRunPrLabel`.
- A `goal_run_class` scalar field (default value `goal-run`) plus a `goal_run_issue` field, folded into the PR body's `<!-- pipeline-metrics -->` block through the existing `Invoke-PipelineMetricsV4Emit` primitive. Both fields are additive-safe: a reader that does not know about them silently ignores them.

**The join key is `goal_run_class` (or, equivalently, the `goal-run` label) on the PR side.** A future escape-rate query segments the frame-credit-ledger's per-PR review-defect counts by joining on that key: PRs where `goal_run_class == 'goal-run'` (or carrying the `goal-run` label) are goal-run-produced; every other PR in the ledger is Code-Conductor-orchestrated. No query tool exists yet — this section documents the join key and the intended analysis shape (per-PR defect count grouped by goal-run vs. non-goal-run) so a future maintainer can write it directly against the ledger and `gh pr list --label goal-run` without re-deriving which field to key on.

## Untrusted-Content Discipline (M4/M5/M12)

Three separate guardrails stand between content the harness does not fully trust — a transcript event, a live issue comment that could have been edited after launch, or executor-supplied evidence text — and any durable artifact the harness writes:

- **Launch-pinned contract-hash check** (step 5) — `Test-GoalRunContractHashPinned` ([goal-run-prompt-core.ps1](../../.github/scripts/lib/goal-run-prompt-core.ps1)) compares the *live* issue-body contract hash against the hash pinned at launch time, not the contract's own self-reported `contract_hash` field — this catches a post-approval edit that kept its own field internally consistent. A mismatch is the highest-precedence halt producer, `invariant-conflict`.
- **Transcript allow-list + secret-redaction pass** (step 1) — `Select-GoalRunAllowedFields` ([goal-run-transcript-core.ps1](../../.github/scripts/lib/goal-run-transcript-core.ps1)) copies only explicitly named keys out of a raw transcript event and also rejects a nested dictionary or non-string enumerable found under an allow-listed key name, so a poisoned event cannot smuggle structured content in under a trusted key. `Get-GoalRunRedactedText` then runs a fixed set of secret-shaped regexes (GitHub/AWS/Slack tokens, PEM private-key blocks, bearer tokens, generic `key=value` secret assignments) over any string headed for a durable artifact, replacing each match with a `[REDACTED:<pattern-name>]` placeholder.
- **Executor-evidence inert-render discipline** (step 1) — `ConvertTo-GoalRunInertEvidenceText` ([goal-run-halt-core.ps1](../../.github/scripts/lib/goal-run-halt-core.ps1)) strips marker-delimiter substrings out of `evidence[]`/`plan_remediation` text before a halt report is posted, so executor-authored text cannot smuggle a live `<!-- ... -->` marker literal into a durable comment. `Invoke-GoalRunHaltEmit` applies this and schema-validates before ever posting — it is never bypassed by constructing a raw comment string.

Any transcript-derived or executor-supplied string reaching a halt report or a PR body fragment must already have passed through the allow-list extractor and the redaction pass; the halt-report schema's closed shape (`additionalProperties: false`) cannot itself enforce that upstream discipline, only the field shape.

## Gotchas

| Trigger | Gotcha | Fix |
| --- | --- | --- |
| Polling `stream-json` stdout for the loop's release verdict | `goal_status` is transcript-only and never reaches `stream-json` stdout on either platform (goal-loop-capability-probe finding) — a harness watching stdout is blind to release | Only read the verdict after control genuinely returns to the harness session, via `Resolve-GoalRunControlReturn`'s bounded transcript retry |
| Calling `Resolve-GoalRunHaltPrecedence` on every halt | The function only matters when two or more of the five producers are true at once | A single-condition halt (e.g. loop-released retry exhaustion) goes straight to the report builder |
| Assuming a `chain-dispatched` marker on resume means work remains | A PR that already carries both the `goal-run` label and the classing metrics is genuinely complete | Call `Test-GoalRunPrEmissionsVerified` against the run's known PR before assuming any work remains |

## Release-Hygiene Note

This file and its `schemas/*.json` siblings sit under `skills/*`, one of the bare glob patterns `Get-FVPluginEntryPointPatterns` ([frame-predicate-core.ps1](../../.github/scripts/lib/frame-predicate-core.ps1)) classifies as a cache-keyed plugin entry point — any path under `skills/**` counts, not just files with a sibling `SKILL.md`. Claude Code's plugin cache is keyed by the `version` in `.claude-plugin/plugin.json`; a same-version reinstall keeps serving whatever entry-point snapshot that version last had. This file is a new entry point added after this PR's step-4 version bump already landed, so it requires its own coalesced `bump-version.ps1` bump — see this step's dispatch report for the resulting version.
