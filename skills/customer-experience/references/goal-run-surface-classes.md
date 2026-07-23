<!-- markdownlint-disable-file MD041 MD003 -->

# Goal-Run Harness Surface Classes (874-D8)

Extracted classification for the [customer-experience](../SKILL.md) composite: which surfaces of the goal-run harness (issue #874 — a launcher/resumer that walks a single GitHub issue's approved goal-contract through to a reviewed pull request without a human answering mid-run prompts; methodology home is [skills/goal-run/SKILL.md](../../goal-run/SKILL.md)) a future CE Gate (Customer Experience Gate — the final validation step verifying the implementation achieves the intended customer experience) exerciser re-runs live, versus which ones fall back to code-audit. This doc does not itself run a CE Gate — issue #874 plan step 12 does, later — it only fixes the classification each surface must be exercised under so that step doesn't have to re-derive it.

## Rule (874-D8)

- **Read-safe surfaces** — rendering, detection, and read-only CLI output that cannot mutate durable state — are re-exercised **live** by Experience-Owner in fresh context at the CE Gate. Live exercise evidence is recorded with `evidence_type` (the field that reflects how a recorded result's evidence was obtained — see `skills/bdd-scenarios/SKILL.md`'s unified evidence record schema for the authoritative field definition) set to `live-interaction`.
- **Mutating surfaces** — commits, comment posting, and teardown, i.e. anything that writes a durable artifact (a GitHub comment/PR/label, a git commit, a worktree removal) — fall back to **code-audit**: the exerciser reads the implementation and cross-references it against the executor's in-run evidence log, rather than re-triggering the mutation live. This follows the same read-safe/mutating split as goal-contract validator precedent 848-D6 (cited for precedent only; not required reading for this doc). Code-audit evidence is recorded with `evidence_type: code-audit`.
- **Every row** in the inventory below carries an `evidence_type` column plus a **provenance pointer** — the specific run-log entry type (`checkpoint | deviation | experience-observation | halt-claim`, [goal-run-log.schema.json](../../goal-run/schemas/goal-run-log.schema.json), issue #874 plan step 1) that backs or corroborates the row's evidence. Where a surface's mutation genuinely precedes any run-log entry (the run log is only written once the loop is `loop-launched` — see the stage machine in [skills/goal-run/SKILL.md](../../goal-run/SKILL.md) `## Stage-Machine Contract`), the row says so honestly instead of forcing a fit.

## Surface Inventory

### Read-safe (live-interaction)

| Surface | Real function / file | evidence_type | Run-log provenance |
| --- | --- | --- | --- |
| Halt-report rendering | `Invoke-GoalRunHaltEmit` / `New-GoalRunHaltCommentBody` (`.github/scripts/lib/goal-run-halt-core.ps1`) | `live-interaction` | `halt-claim` entry when the halt originated from the executor's own claim, corroborated by an `experience-observation` entry recording Experience-Owner's live render check of the posted comment |
| Cleanup-detector's goal-run exclusion/reporting output | `Get-SCDGoalRunProtectedLines` (`skills/session-startup/scripts/session-cleanup-detector-core.ps1`) | `live-interaction` | `experience-observation` entry (Experience-Owner triggers session-startup live and observes the rendered protected-worktree lines) |
| Mutex-refusal message on a concurrent `/goal-run` launch | `agents/Goal-Run.agent.md` `### pre-loop (mutex + provisioning)`, backed by `Invoke-GoalRunMutexLaunch`'s `Outcome: yielded` path (`.github/scripts/lib/goal-run-stage-core.ps1`) | `live-interaction` | `experience-observation` entry (Experience-Owner races a second launch and observes the yield message live) |
| "Run appears dead" resume/triage nudge | `agents/Goal-Run.agent.md` line 42 (`triage-dead-run` outcome), backed by `Test-GoalRunInflightAppearsDead` + `Resolve-GoalRunInvocationAction` (`.github/scripts/lib/goal-run-stage-core.ps1`) | `live-interaction` | `experience-observation` entry (Experience-Owner observes the nudge against a deliberately stale inflight marker) |
| Session-startup deferred-teardown-retry rendered command | `Get-SCDGoalRunProtectedLines` (`skills/session-startup/scripts/session-cleanup-detector-core.ps1`, retry-command render) | `live-interaction` | `experience-observation` entry (Experience-Owner observes the rendered `Invoke-GoalRunDeferredTeardownRetry` command line) |

### Mutating (code-audit)

| Surface | Real function / file | evidence_type | Run-log provenance |
| --- | --- | --- | --- |
| Worktree provisioning | `New-GoalRunWorktree` (`.github/scripts/lib/goal-run-worktree-core.ps1`) | `code-audit` | The run's first `checkpoint` entry (its `commit_sha` proves a commit landed inside the provisioned worktree); the total absence of any `checkpoint` entry is itself evidence provisioning never got past `pre-loop` |
| Worktree teardown | `Remove-GoalRunWorktree` (`.github/scripts/lib/goal-run-worktree-core.ps1`) | `code-audit` | The run's final `checkpoint` entry (confirms the worktree was live through the last recorded commit), cross-referenced against `goal-run-active.json`'s `teardown_deferred` flag — teardown's own outcome is written to that state file, not to a run-log entry, so this row's provenance is deliberately a corroborating `checkpoint`, not a direct one |
| Inflight marker comment post | `New-GoalRunInflightMarker` (`.github/scripts/lib/goal-run-stage-core.ps1`) | `code-audit` | None directly — the mutex marker post happens during `pre-loop`, before the run log exists. The posted comment itself is the durable artifact under audit; the first `checkpoint` entry written after `loop-launched` corroborates that the marker's pinned `contract_hash` matches the run that actually executed |
| PR creation + classing | `Invoke-GoalRunClassEmission` / `Add-GoalRunPrLabel` (`.github/scripts/lib/goal-run-chain-core.ps1`) | `code-audit` | The run's final `checkpoint` entry's `commit_sha`, cross-referenced against the created PR's head commit |
| Fix-cycle dispatch (live subagent edits) | `agents/Goal-Run.agent.md` `### Stage 4 — Fix dispatch, capped`, capped via `Test-GoalRunFixCycleCapExceeded` (`.github/scripts/lib/goal-run-chain-core.ps1`) | `code-audit` | `deviation` entries (each fix cycle's rationale for departing from the original plan) plus the `checkpoint` entry each fix cycle produces |
| The goal loop execution itself | `agents/Goal-Run.agent.md` `### loop-launched (Arm I executor)` — the vendor `/goal` loop launch | `code-audit` | `checkpoint` / `deviation` / `experience-observation` entries written during the loop are themselves the loop's primary audit trail — this is the one mutating surface where the run log is the direct evidence source rather than a corroborating one |

## Cross-Reference

This doc's classification is downstream of the harness mechanics documented in [skills/goal-run/SKILL.md](../../goal-run/SKILL.md) — read that skill first for the stage-machine contract, halt model, worktree lifecycle, and untrusted-content discipline that the surfaces above are built from. `skills/goal-run/SKILL.md`'s own `## When to Use` section points forward to this doc.
