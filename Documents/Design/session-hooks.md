# Design: Session Hooks

> **Current state — Issue #409**: hook-based delivery returned, but now through plugin-distributed hook files rather than workspace-discovered `.github/hooks/session-cleanup.json`. Claude-format installs use `hooks/hooks.json`; Copilot-format installs use root `hooks.json` because Copilot does not define `${CLAUDE_PLUGIN_ROOT}`. The `session-startup` skill remains the agent-side contract for consuming injected `additionalContext`, preserving the run-once marker `/memories/session/session-startup-check-complete.md`, and keeping manual detector runs available. The plugin-release-hygiene `PostToolUse` hook now ships through the same plugin-distributed architecture. Historical context below is preserved so the earlier hook → instruction → skill eras remain traceable.
>
> Claude Code startup also includes a Claude-only Step 7b plugin drift backstop. Before reading the cached marketplace version, Step 7b attempts `claude plugin marketplace update` with a 5-second timeout. Timeout, non-zero exit, or unavailable `claude` emits `marketplace freshness check failed — using cached view` and continues from cache without retrying freshness; local-path non-git and dirty/detached classifications suppress that generic emit because their remediation is more specific. Headless runs perform the same freshness attempt and fail-open emission, suppressing only the post-drift stop/continue prompt. The later `claude plugin update agent-orchestra@agent-orchestra --yes` path keeps its separate 30-second timeout and retry behavior. Step 7b shares the existing Step 4 run-once marker; no second marker is introduced. Version 2.5.2 is the cache-invalidation release for this startup surface.
>
> Session-state survival for the run-once startup marker is governed by [skills/session-memory-contract/SKILL.md](../../skills/session-memory-contract/SKILL.md) (`SMC-07`); release-hygiene hook state is governed by `SMC-12`.
>
> **Issue #889 update**: the orphan-branch and sibling-worktree removal logic this hook flow triggers (step 6 below) was substantially reworked. See [§ Worktree & Branch Removal Eligibility and Honest Outcome Reporting](#worktree--branch-removal-eligibility-and-honest-outcome-reporting-issue-889) below for the evidence-ladder eligibility primitive, the shared primary-worktree guard, and the honest removal-outcome enum that replaced a prior false-"skipping" reporting defect.
>
> **v2.0.0 update (agent-orchestra rename)**: The `COPILOT_ORCHESTRA_ROOT` / `WORKFLOW_TEMPLATE_ROOT` env-var surface described in D7, D9, and the setup-requirement text below was removed in v2.0.0. The detector wrapper at `skills/session-startup/scripts/session-cleanup-detector.ps1` now self-resolves its repo root via `$PSScriptRoot`, so no environment variables are required for either plugin-cache or direct-clone installs. Silent-skip still applies when `pwsh` is unavailable or the detector returns non-JSON output.

## Summary

The current design uses plugin-distributed hooks to restore deterministic startup automation across both Claude Code and Copilot. Claude-format installs use the standalone `hooks/hooks.json` bundle/discovery path, while `.claude-plugin/plugin.json` intentionally omits `hooks`; Copilot-format installs use root `hooks.json`, declared by the root `plugin.json`. Both hook files carry `SessionStart` for stale-state cleanup context injection and `PostToolUse` for plugin-release-hygiene version-bump prompting. The `session-startup` skill remains responsible for run-once semantics, detector-output handling, fail-open behavior, opt-in cleanup, manual fallback invocation, and Claude-only marketplace freshness before plugin drift checks.

Code-Critic Perspective 7 (Documentation Script Audit) was added in the same phase to close a gap where shell commands embedded in Markdown documentation went unreviewed for self-consistency. _(Merged into §6 Script & Automation as doc-audit sub-gate in issue #212.)_

---

## Design Decisions

Era values: Hook | Instruction | Skill | Plugin hook | Auto-resolve (business-logic decisions inside the plugin-hook-delivered cleanup script).

| # | Decision | Choice | Rationale | Era |
|---|----------|--------|-----------|-----|
| D1 | Cleanup mechanism | VS Code `SessionStart` hook | Fires at the natural post-merge moment; zero overhead for sessions with nothing to clean | Hook |
| D2 | Confirmation model | Agent-mediated via `vscode/askQuestions` | `PreToolUse` is the only hook with `permissionDecision: "ask"` but does not fit the trigger pattern; agent-mediated confirmation is functionally equivalent | Hook |
| D3 | Janitor retirement | Remove entirely; absorb all capabilities | Mechanical work moved to hook; judgment work absorbed by existing pipeline stages | Hook |
| D4 | Implementation language | PowerShell (`.ps1`) | Cross-platform via `pwsh`; supports both parameterized invocation and hook-triggered flow | Hook |
| D5 | Issue closure | `Closes #N` in PR body | GitHub auto-close is sufficient — no summary comment needed | Hook |
| D6 | Knowledge capture | Dropped | Pipeline already produces durable artifacts (design in issue body, `Documents/Design/` file, PR description); rare novel insights are left as manual developer actions | Hook |
| D7 | Hook portability | `WORKFLOW_TEMPLATE_ROOT` env var | Explicit and transparent; works across all repos; no dynamic resolution needed; hook-era unset behavior: fail with a clear actionable error, not silent no-op (see D9 for instruction-era behavior) | Hook |
| D8 | Hook retirement | Retire `SessionStart` hook entirely | Hook fires unreliably across different repos (works in some, silently fails in others at the OS/IDE level regardless of configuration); instruction files via `chat.instructionsFilesLocations` are more reliable and simpler to maintain | Instruction |
| D9 | Instruction/skill replacement | First `session-startup.instructions.md`, now the `session-startup` skill with a per-agent trigger stub on the first content line after the role description in each pipeline-entry agent file | Delivery moved from an always-loaded shared instruction to a plugin-distributable skill while preserving the same agent-mediated confirmation model (D2), no VS Code version gate, and the same `WORKFLOW_TEMPLATE_ROOT`-based silent-skip behavior before the script runs | Instruction → Skill |
| D10 | Automatic run-once behavior | Session-memory marker `/memories/session/session-startup-check-complete.md` checked before the automatic detector run and recorded after the first automatic startup check | Prevents repeated prompts across later agent hops in the same conversation while keeping the detector script stateless and manual reruns available | Instruction |
| D11 | Calibration cleanup noise | Treat `.copilot-tracking/calibration/**` as persistent data, not cleanup work | Avoids false-positive cleanup prompts for repo-scoped calibration state | Instruction |
| D12 | Trigger placement within agent files | Put the `session-startup` trigger on the first content line after the role description in each pipeline-entry agent and remove the redundant silent-skip summary from `## Process` | Reduces instruction competition in crowded `## Process` sections, especially for Experience-Owner, while keeping silent-skip and run-once semantics owned by the skill contract and wording test | Skill |
| D13 | Hook delivery comeback | Return to hook-based delivery via plugin-distributed `hooks/hooks.json` | Avoids the unreliable workspace-discovered hook mechanism from issue #109 while removing LLM-priority dependence from per-agent trigger text | Plugin hook |
| D14 | Hook discovery/declaration path | Use standalone `hooks/hooks.json` for Claude bundle discovery and declare `hooks.json` only in the root Copilot `plugin.json` | Keeps hook delivery explicit while preserving Claude's metadata-only manifest contract and accommodating Copilot's missing plugin-root token | Plugin hook |
| D15 | Shared hook file scope | Carry both `SessionStart` and `PostToolUse` in the same hook file | Keeps startup hygiene and release hygiene under one plugin-distributed hook surface and reduces drift between tools | Plugin hook |
| D16 | Release-hygiene hook location | Move `plugin-release-hygiene-hook.ps1` into `skills/plugin-release-hygiene/scripts/` | Co-locates the hook script with its owning skill and removes the old `.claude/settings.json` / `.claude/hooks/` maintainer-only path | Plugin hook |
| D17 | Claude marketplace freshness | Run `claude plugin marketplace update` before the Step 7b cached version comparison | Prevents stale marketplace clones from creating false-current silence while preserving fail-open startup behavior | Plugin hook |
| D18 | Auto-resolve eligibility rule | Tri-state `$true`/`$false`/`$null`; fail-open on `$null`; cleanup-time evaluation only | Preserve existing conservative behavior when signals are unavailable; surface undeletable branches for manual review; avoid per-session gh latency | Auto-resolve |
| D19 | Stray-content tolerance boundary | Moderate with tree-at-HEAD: per-commit absorption (ancestor-on-main / patch-equivalent / spike-only-per-IssueId with `--allow-empty` rejection / tree-at-HEAD-matches-main) | Strict (spike-only or fingerprint) misses reworded-squash #535 class; aggressive (closed+merged alone) risks data loss; moderate-with-tree-at-HEAD closes the recall gap at marginal coincidence-of-trees risk | Auto-resolve |
| D20 | Eligibility evaluation location | Cleanup-time (inside `Remove-OrphanBranch`) | No per-session gh latency; stale-state gap avoidance (signals evaluated immediately before deletion) | Auto-resolve |
| D21 | CLOSED stateReason authorization | Any CLOSED stateReason accepted (NOT_PLANNED, DUPLICATE, COMPLETED) | Cleanup convergence over branch preservation; intent-respect at issue-closure time; conservative skip-on-NOT_PLANNED rejected | Auto-resolve |
| D22 | Per-line wording surface | Detector adds `; eligible for auto-resolve at cleanup time` suffix for `feature/issue-N-*` orphans; cleanup script splits skip wording into `auto-resolve declined`, `could not verify auto-resolve signals`, and `branch not reachable from default (merged-state re-check returned false)` | Preamble-only annotation easy to skim past; universal suffix misrepresents `claude/*` orphans; both-surfaces provides per-line visibility at detector time and precise skip context at cleanup time | Auto-resolve |
| D23 | Zero-unique-commit branch eligibility | `Test-WorktreeBranchRemovalEligible` requires OID-checked merged-PR-by-head evidence, then closed-issue-state evidence — never git-only tree-equivalence | A zero-unique-commit branch is tree-equivalent to the default branch by definition (no commits, no diff); trusting that as merge evidence was the exact 2026-07-20 incident root cause | Evidence ladder |
| D24 | ≥1-unique-commit branch eligibility (shared primitive path) | Git-only tree-equivalence first, then the primitive's own OID-checked merged-PR-by-head rung; never the name-only `gh` fallback (M4) | Keeps the fast git-only path for genuinely-merged branches while closing the identity gap where a same-named-but-different PR could be mistaken for evidence | Evidence ladder |
| D25 | Shared primary-worktree guard | Single `Test-WorktreeIsPrimary` (first `git worktree list --porcelain` record) called identically by the detector and the executor; fail-safe returns `$true` (primary, never removable) on any probe failure | Closes the 2026-07-20 incident gap where the primary checkout could be offered for deletion; one implementation prevents the two call sites from silently diverging | Evidence ladder |
| D26 | Honest removal-outcome reporting | Six-state closed enum (`Get-WorktreeRemovalOutcome`: `removed`, `removed-partial-root-held`, `removed-partial-content-remains`, `stale-registration`, `failed`, `verification-indeterminate`) derived purely from injected post-removal probes | Old `Test-Path`+porcelain-scan inference produced a false "skipping" message while a removal attempt had already partially destroyed a worktree — the incident that opened #889; pure-over-injected-probes design lets fixtures simulate Windows-only held-directory post-states CI cannot produce live | Evidence ladder |
| D27 | Shared-primitive scope (bet, partially held) | `Test-WorktreeBranchRemovalEligible` is shared across the sibling-worktree path, the zero-unique-commit orphan-branch path, and the detector's read-only wrapper; the ≥1-unique-commit orphan-branch path (`Remove-OrphanBranch` in `post-merge-cleanup.ps1`) reverted to the pre-#889 `Test-BranchMergedIntoDefault` + `Test-OrphanBranchAutoResolveEligible` chain | An in-dispatch attempt to route every orphan-branch case through the shared primitive broke two pre-existing real-git-backed test suites the dispatch didn't know about (#513/#548 squash/rebase/patch-equivalence absorption sub-cases, and a static wording-contract test); reverting that one path was the safer fix, not the original design intent — flagged by code review as Cluster A, not authored as a deliberate architecture choice | Evidence ladder |

---

## Worktree & Branch Removal Eligibility and Honest Outcome Reporting (Issue #889)

**Root cause**: `git worktree remove` is not atomic on Windows. A removal attempt can delete a worktree's contents while the registration in `git worktree list` or the root directory itself still fails to clear — the old detection code (a `Test-Path` + porcelain-scan inference) misdiagnosed that partial state as "nothing happened" and printed a skip message while the worktree had, in fact, already been partially destroyed. That misdiagnosis is the incident #889 was filed to fix.

**Evidence-ladder eligibility** (`Test-WorktreeBranchRemovalEligible` in `skills/session-startup/scripts/session-startup-git-helpers.ps1`, issue #889 s1): replaces the old "reachable from origin/main" heuristic, which trusted git tree-equivalence even for branches with zero unique commits — trivially true by definition, and exactly the signal a not-yet-worked-on `claude/*` branch would also produce. The router:

1. **Unique-commit count** (`git rev-list <remoteDefault>..<branch> --count`, network-free, runs first). Any git failure or unparseable count fails closed toward "not eligible — review".
2. **≥1 unique commit**: git-only tree-equivalence, then OID-checked merged-PR-by-head (never a name-only `gh` fallback). See D24.
3. **0 unique commits**: OID-checked merged-PR-by-head first, then derived-issue-id + closed-issue-state. Positive GitHub evidence is required — git alone cannot distinguish a genuinely-absorbed zero-commit branch from a freshly-created one. See D23.

Any git/gh failure, timeout, `$null`, or malformed JSON resolves toward **not eligible** — the primitive never fails open toward deletion.

**Shared-primitive architectural bet**: one function, called from every removal-decision site, was the bet against the "5 call sites re-implement and diverge" failure mode. That bet held for the shared primary-worktree guard (D25) and for the sibling-worktree and zero-commit-orphan-branch paths. It did **not** fully hold for the ≥1-unique-commit orphan-branch path — see D27. Be honest about this in any future audit: `Remove-OrphanBranch`'s ≥1-commit case still calls the older `Test-BranchMergedIntoDefault` + `Test-OrphanBranchAutoResolveEligible` chain (D18-D22 above), not the shared primitive.

**Honest-reporting outcome enum**: see D26. `Get-WorktreeRemovalOutcome` is pure over two injected probes (a porcelain-registration check and a filesystem-state check) so its six outcomes can be exercised by fixtures that simulate held-directory post-states CI cannot reproduce live (holding a directory open across a test process). `'skipped-intact'` is a separate, caller-synthesized message (`post-merge-cleanup.ps1`) for a pre-flight skip where no removal was attempted at all — it is not a member of this function's return enum.

**Adjacent concern**: the persistent-tracking-registry exclusion guard in the same executor (`post-merge-cleanup.ps1`, `mf6-executor-failsafe`) is a related but distinct subsystem — see [session-cleanup-persistent-exclusion-registry.md](session-cleanup-persistent-exclusion-registry.md). That guard currently enforces only the `Filenames` axis at the executor, while the detector enforces both `Filenames` and `Subtrees`; a code-review finding during #889 (Cluster A / N6) flagged this as a latent contract gap (currently inert — no tagged file exists under the protected subtree today) and it was filed as follow-up [#896](https://github.com/Grimblaz/agent-orchestra/issues/896) rather than fixed in #889's scope.

Full adversarial-review trail, incident detail, and stress-test findings live on [issue #889](https://github.com/Grimblaz/agent-orchestra/issues/889); this section documents only the resulting architecture.

---

## Capability Map

| Former Janitor Capability | New Home |
|---|---|
| Archive tracking files | `session-startup` skill → `post-merge-cleanup.ps1` _(as of issue #345; formerly `session-startup` instruction, and before that the `SessionStart` hook)_ |
| Delete branches (local + remote) | `post-merge-cleanup.ps1` |
| Switch to main + git pull | `post-merge-cleanup.ps1` |
| Close GitHub issue | `Closes #N` in PR body (automated by Code-Conductor) |
| Summary comment on issue | Dropped (PR description is the durable record) |
| Tech debt issue closure | Code-Conductor adds `Closes #tech-debt-N` to PR body |
| Knowledge capture (ADRs) | Dropped (pipeline artifacts suffice) |
| Remove obsolete files | Already handled by Code-Smith / Refactor-Specialist |

---

## Hook Flow (User Experience)

1. Code-Conductor creates PR with `Closes #N` → session ends
2. User reviews and merges PR on GitHub (issue auto-closes)
3. User starts a new agent session (any agent)
4. The plugin-distributed `SessionStart` hook runs `session-cleanup-detector.ps1` before the agent sees the request and injects any resulting `additionalContext` into the first turn.
5. The `session-startup` skill first looks for the session-memory run-once marker `/memories/session/session-startup-check-complete.md`. If the marker is absent, the first automatic startup check is honored; later agent hops in the same conversation skip that automatic path.
6. The detector evaluates cleanup signals in this order:
   - **Current branch**: detects an upstream-deleted current branch, plus a current `claude/*` no-upstream worktree branch only when its HEAD is reachable from the resolved remote default branch. Current-worktree cleanup commands are narrative inline text outside the fenced block so the auto-run path cannot remove its own checkout.
   - **Tracking files**: detects stale issue-scoped `.copilot-tracking/` files for issues whose remote `feature/issue-*` branch is gone; persistent calibration data is excluded.
   - **Sibling worktrees**: detects sibling worktrees on merged `claude/*` no-upstream branches and sibling `feature/issue-*` branches whose upstream branch was deleted; cleanup commands are inside the fenced block.
   - **Orphan branches**: detects unattached merged `claude/*` no-upstream branches and unattached upstream-deleted `feature/issue-*` branches (squash-merged branches recognized via `git diff` tree-equivalence since issue #513); cleanup commands are inside the fenced block. Zero-unique-commit orphan branches route through the evidence-gated `Test-WorktreeBranchRemovalEligible` primitive (issue #889 — see § Worktree & Branch Removal Eligibility below) rather than trusting trivially-true tree-equivalence.
   - **Fail-open behavior**: fetch, worktree-list, for-each-ref, per-candidate merge-base, and ref-lookup failures skip unverifiable candidates without failing the startup flow.
   - **Opt-in cleanup**: the detector reports findings only; cleanup runs only after user confirmation.
7. After that first automatic startup check, the `session-startup` skill records `/memories/session/session-startup-check-complete.md` regardless of whether cleanup will later be accepted, declined, or skipped.
8. The `session-startup` skill surfaces `additionalContext` describing what needs cleanup (branch signal leads when both fire).
9. Agent asks user via `vscode/askQuestions`: context reflects which signal(s) fired and asks whether to run the fenced cleanup block.
10. If confirmed → runs only the fenced commands. All cleanup — including current/tracking-file, sibling worktree, and orphan branch cleanup — goes through `post-merge-cleanup.ps1`, invoked as a composite `pwsh ... post-merge-cleanup.ps1 -SiblingWorktrees @(...) -OrphanBranches @(...)` call (composite invocation eliminates per-command permission prompts; see issue #500).
11. Cleanup remains opt-in. Current-worktree inline commands are manual instructions that must be run from another checkout.
12. Claude Code then runs Step 7b under the same startup run-once marker. Before reading cached marketplace state, it attempts `claude plugin marketplace update` for up to 5 seconds.
13. Freshness failures emit `marketplace freshness check failed — using cached view` and continue from cache without retrying freshness. Local-path non-git and dirty/detached classifications use their existing remediation text instead of the generic freshness emit.
14. If drift is detected, `claude plugin update agent-orchestra@agent-orchestra --yes` keeps its independent 30-second timeout and retry path. Interactive runs ask whether to restart or continue under old code; headless runs emit the result inline and continue.

---

## Plugin Distribution Architecture

Hook delivery now ships through plugin-distributed hook files rather than workspace-level `chat.hookFilesLocations` configuration. Claude Code loads the standalone `hooks/hooks.json` bundle/discovery path, and `.claude-plugin/plugin.json` intentionally omits a `hooks` field. Copilot loads root `hooks.json` through the root `plugin.json` `hooks` declaration. Downstream installs therefore receive the startup and release-hygiene hooks automatically in both formats without giving Claude a manifest hook declaration.

The detector wrapper at `skills/session-startup/scripts/session-cleanup-detector.ps1` still self-resolves its repo root via `$PSScriptRoot`, which preserves the v2.0.0 removal of `COPILOT_ORCHESTRA_ROOT` / `WORKFLOW_TEMPLATE_ROOT` as runtime requirements. Manual fallback invocation therefore remains path-stable in both repo-clone and plugin-cache contexts.

Claude plugin caches are keyed by manifest version, so startup-surface changes that affect installed plugin behavior require a manifest version bump. Version 2.5.2 invalidates the cache for the marketplace freshness probe.

---

## Code-Critic Perspective 7: Documentation Script Audit _(merged into §6 in #212)_

Added alongside the portability fix to close a gap found in the post-PR review of issue #36: `copilot-instructions.md` quick-validate commands always self-matched because the file hosting the command was inside the searched path.

**Gate**: Only applies to `.md` files that contain shell or PowerShell code blocks.

**Checklist** (3 items):

1. Every runnable command in a code block produces the documented output when run in a clean clone — no stale commands.
2. Grep/Select-String patterns that search `.github/` exclude the file that hosts the command itself (self-match prevention).
3. Numeric counts in documentation (e.g., "must be 0", "must be 13") match the actual state of the repo.

**Numbering**: Perspective 6 (Script & Automation Files) was added in PR #38 between when issue #39 was filed and when it was implemented; Documentation Script Audit is therefore Perspective 7. _(Both merged into a single §6 Script & Automation perspective with branching gate in issue #212; total perspective count reduced from 7 to 6.)_

---

## Implementation Files

| File | Purpose | Status |
|------|---------|--------|
| `.github/hooks/session-cleanup.json` | `SessionStart` hook configuration; resolves scripts via `$WORKFLOW_TEMPLATE_ROOT`; structured JSON error when unset | **Deleted** — retired in issue #109 |
| `.github/instructions/session-startup.instructions.md` | Historical intermediate delivery vehicle between the retired hook and the current skill; checked the session-memory run-once marker `/memories/session/session-startup-check-complete.md` before the automatic detector run, recorded the marker after the first automatic startup check, and used `$env:COPILOT_ORCHESTRA_ROOT` (fallback: `$env:WORKFLOW_TEMPLATE_ROOT`) for script paths | **Historical** — superseded by `skills/session-startup/SKILL.md` (issue #345) |
| `hooks/hooks.json` | Claude-format plugin-distributed hook configuration carrying `SessionStart` and `PostToolUse` | **Active** — introduced in issue #409 |
| `hooks.json` | Copilot-format plugin-distributed hook configuration carrying `SessionStart` and `PostToolUse` via explicit cache-root resolution | **Active** — introduced in issue #409 |
| `skills/session-startup/SKILL.md` | Current agent-side protocol for consuming hook-injected startup context; preserves run-once, fail-open, manual fallback, opt-in cleanup, and Claude-only Step 7b drift-check semantics | Active |
| `skills/session-startup/platforms/claude.md` | Claude-specific startup invocation notes, including AskUserQuestion labels and marketplace freshness behavior | Active |
| `skills/session-startup/scripts/session-cleanup-detector.ps1` | Startup cleanup detector for current branches, issue-scoped tracking files, sibling worktrees, and orphan branches; persistent calibration paths are excluded; emits cleanup commands without env-var requirements | Active — updated (issue #185, migrated to skill path in issue #360, expanded for Claude worktrees in issue #452) |
| `skills/session-startup/scripts/post-merge-cleanup.ps1` | Archives tracking files, deletes local/remote branch (squash-merge-aware via tree-equivalence detection), syncs default branch, removes sibling worktrees via the honest outcome enum | Active — migrated to skill path in issue #360, squash-merge detection added in issue #513, evidence-gated eligibility + honest removal-outcome reporting added in issue #889 |
| `skills/session-startup/scripts/session-startup-git-helpers.ps1` | Shared primitives dot-sourced by both the detector and the executor: `Test-WorktreeBranchRemovalEligible` (evidence-ladder eligibility), `Test-WorktreeIsPrimary` (primary-worktree guard), `Get-WorktreeRemovalOutcome`/`Get-WorktreeRemovalOutcomeMessage` (honest outcome enum), plus the persistent-tracking exclusion registry accessor (issue #656) | Active — introduced in issue #366/#367 (skills migration), squash-merge tree-equivalence added in issue #513, exclusion registry added in issue #656, evidence-gated eligibility + primary guard + honest outcome enum added in issue #889 |
| `skills/plugin-release-hygiene/scripts/plugin-release-hygiene-hook.ps1` | Plugin-distributed `PostToolUse` hook script for entry-point version-bump proposals | **Active** — moved from `.claude/hooks/` in issue #409 |
| `.claude/settings.json` | Former maintainer-local `PostToolUse` hook configuration for release hygiene | **Deleted** — superseded by `hooks/hooks.json` in issue #409 |

---

## Inline-Dispatch Contract

The inline-dispatch contract was added for issue #412, updated by issue #437, re-shaped into a DRY load-reference contract by issue #498, and then simplified by the provenance-gate retirement. Each Claude command file now carries a single load reference to `skills/session-startup/SKILL.md` (Steps 4, 6, 7b, 9) plus a command-specific `### Step 9 — Paired-body halt-on-fail` D1 body-resolution cascade block immediately after the load reference. The opening-phase framing/orientation responsibility is now owned by `skills/upstream-onboarding/SKILL.md`, which the agent body itself loads from its Process section when an issue-referencing request arrives — not the command file. `.github/scripts/Tests/inline-dispatch-contract.Tests.ps1` asserts the DRY load-reference shape and a negative-shape guard that no command file references the retired provenance-gate skill. Canonical option labels extracted from the fenced YAML block in `skills/session-startup/SKILL.md` remain the single source of truth for label-drift tests.

| Command file | Pre-flight load reference | Per-command inline content |
| --- | --- | --- |
| `commands/experience.md` | session-startup | Step 9 D1 cascade for `agents/Experience-Owner.agent.md` |
| `commands/design.md` | session-startup | Step 9 D1 cascade for `agents/Solution-Designer.agent.md` |
| `commands/plan.md` | session-startup | Step 9 D1 cascade for `agents/Issue-Planner.agent.md`; inline adversarial-pipeline dispatch section |
| `commands/orchestrate.md` | session-startup | Step 9 D1 cascade for `agents/Code-Conductor.agent.md`; smart-resume marker handling; downstream Agent handshake guidance |
| `commands/polish.md` | session-startup | Step 9 D1 cascade for `agents/UI-Iterator.agent.md` |

Historical note: issue #412 originally treated direct `/plan` as a carve-out for Step 9 and provenance. Issue #437 reversed that carve-out. Issue #465 extended the inline-dispatch contract to `/orchestrate`, and `/polish` joined the contract surface later. Issue #498 re-shaped all five command files into the DRY load-reference contract above. The provenance-gate retirement then removed the second load reference to the gate skill (and the gate skill itself), collapsing the cold-pickup self-classification flow into the simpler `upstream-onboarding` brief loaded from the agent body.

Cross-tool asymmetry per D6 of #412: Copilot's `.github/prompts/*.prompt.md` files are thin one-line dispatchers without a parent-side prose surface. Copilot inline-dispatch enforcement is owned by the agent body (`agents/{Name}.agent.md`) and is tracked in #414.

---

## Requirements

- The root Copilot `plugin.json` must declare `hooks.json`; Claude's `.claude-plugin/plugin.json` must omit `hooks` and rely on the bundled `hooks/hooks.json` file
- The automatic startup check runs at most once per conversation because the session-memory marker `/memories/session/session-startup-check-complete.md` is checked before the detector run and recorded after the first automatic startup check
- If session-memory read or write fails, the startup flow fails open and still runs the detector rather than suppressing cleanup detection
- Detector git failures fail open: fetch, worktree-list, for-each-ref, per-candidate merge-base, and ref-lookup failures suppress unverifiable candidates without aborting the session
- Explicit manual detector runs remain available after the automatic guard fires
- Linux/macOS without `pwsh`: the hook or manual fallback detects unavailability and skips silently
- If the detector script is missing or the detector returns non-JSON output, the automatic startup check skips silently
- Claude Code Step 7b attempts `claude plugin marketplace update` with a 5-second timeout before reading cached marketplace state
- Freshness timeout, non-zero exit, or unavailable `claude` emits `marketplace freshness check failed — using cached view`, continues from cache, and does not retry freshness
- Local-path non-git and dirty/detached classifications suppress the generic freshness emit because their existing remediation text owns those cases
- Headless Claude runs perform the same freshness attempt and fail-open emission; only the post-drift stop/continue prompt is suppressed
- The later `claude plugin update agent-orchestra@agent-orchestra --yes` path keeps its separate 30-second timeout and retry behavior
- Step 7b shares the existing startup run-once marker and introduces no second marker
