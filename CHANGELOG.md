# Changelog

All notable changes to agent-orchestra will be documented in this file.

## [2.20.0] — 2026-05-27

### Added

- **cognitive-surrender-prevention v1.3** ([#577](https://github.com/Grimblaz/Copilot-Orchestra/issues/577)) — Code-Conductor's `scope-classification` decision now preserves across sessions via a new `phase: orchestration` engagement-record marker class.
  - **Schema bump**: `engagement-record-emission` `schema_version` 2 → 3; `phase` enum extends with `orchestration`. Readers built against v2 throw on unknown `schema_version` (out-of-try hard reject), and v3 markers carrying `phase: orchestration` require `schema_version >= 3` (in-try guard, warn-and-skip per CF13b cross-phase isolation).
  - **Touchpoint narrowing**: `D9-checkpoint` is dropped from Code-Conductor's solution-authoring touchpoint set after classification re-audit (P3.F2 in /design); the touchpoint set is now `scope-classification` only.
  - **Marker mirror policy**: the Markdown mirror is co-located inside the `<!-- engagement-record-orchestration-{ID} -->` comment (NOT in the issue body). CE Gate evaluator scope is widened to read both surfaces — issue-body `## Named Decisions` for upstream phases, comment-mirror for orchestration. Evaluator-side widening is staged behavior (becomes live with #578).
  - **Cross-file constants extended**: `frame-credit-ledger-core.ps1` (`$script:PipelineEntryPorts` / `$script:CompletionMarkerByPort` / `$script:BuilderByPort`), `cost-attribution.ps1` (two literals), `cost-pattern-renderer.ps1`, and `session-memory-contract` SMC-17 / SMC-20 rows all updated to include the new `orchestration` port.
  - **Plugin version bump**: 2.19.0 → 2.20.0 via `bump-version.ps1`, in lockstep with the schema cut to invalidate cached v2-era readers downstream.

> **Audit note (v2.20.0 release-hygiene)**: The Copilot-side files (`plugin.json` at repo root, `.github/plugin/marketplace.json`) jumped 2.18.0 → 2.20.0 in this release, skipping the 2.19.0 entry. The prior 2.19.0 release (#576/#627) bumped only Claude-side files (`.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json`, README badge). The v2.20.0 `bump-version.ps1` invocation reconciles all 7 occurrences across all 5 files. Consumers reading Copilot manifests between releases 2.18.0 and 2.20.0 saw a stale 2.18.0 version. Future bumps should verify all 5 files agree via `bump-version.ps1 -CheckOnly` per ADR-0002 dual-write doctrine. Tracked as review P1.F4 / P2.F17.

## [2.19.0] — 2026-05-25

### Added

- **Project-reference discoverability** (#627) — new `skills/project-references` with sidecar/index schema, content-trust rules, setup/loader scripts, and platform notes. New `/setup-references` command surfaces for Claude Code and Copilot, plus examples and customization docs. Reference loading and citation-discipline guidance integrated into upstream onboarding and customer/design/plan skills so upstream agents can surface authoritative repo docs before authoring decisions.
- **Structural-criteria deferral gate** (#610) — verdict-decision text is now driven by structural criteria rather than effort estimates. New `skills/review-judgment/scripts/Test-DeferralCriteria.ps1` exposes the canonical criterion taxonomy (`S-new-abstraction`, `S-cross-cutting`, `S-design-decision`, `S-schema-or-contract`, `S-different-surface`, `S-maintainer-judgment`).
- **`Add-FollowUpIssue` helper** (#610) — `skills/safe-operations/scripts/Add-FollowUpIssue.ps1` ships `Add-FollowUpIssue`, `ConvertTo-CanonicalFollowupTitle`, and `New-FollowupSentinelBlock` for follow-up issue filing with GraphQL parenting and the `<!-- code-conductor-filed-followup -->` sentinel contract (AC8).
- **`Get-StructuralVerdict` / `Get-AcRefsFromIssue` helpers** (#610) — additional public review-judgment surface used by Code-Conductor and code-review-intake to share a single deferral-decision implementation across both filing paths.

### Changed

- **Verdict category labels** (#610) — `ACCEPT (<1 day)` renamed to `ACCEPT (fix inline)`; `DEFERRED-SIGNIFICANT (>1 day, non-blocking)` renamed to `DEFERRED-SIGNIFICANT (structural)`. Effort-language remnants removed from primary verdict-decision text in `skills/safe-operations/SKILL.md`, `Documents/Design/safe-operations.md`, `Documents/Design/setup-wizard.md`, and `skills/validation-methodology/references/review-reconciliation.md`.
- **`skills/code-review-intake/SKILL.md`** (#610) — cross-references the shared structural-criteria gate so GitHub-intake judgments stay aligned with non-GitHub review verdicts.

## [2.17.0] — 2026-05-20

### Added

- **Squash-merge orphan auto-resolve** (#548 / PR #595) — session-startup cleanup now auto-deletes `feature/issue-N-*` branches that have been squash-merged into main. Adds a three-layer verification chain in `skills/session-startup/scripts/session-startup-git-helpers.ps1`: ancestor reachability → patch-equivalent (`git cherry`) → spike-only / tree-at-HEAD per-residual-commit classification. Authorization requires the parent issue to be CLOSED **and** a merged PR with `headRefOid == git rev-parse $Branch` (the local branch tip SHA), so the auto-delete path only fires for branches whose exact tip was the merged head. New Pester suites: `test-orphan-branch-commits-absorbed.Tests.ps1`, `test-orphan-branch-auto-resolve-eligible.Tests.ps1`, `test-orphan-branch-github-signals.Tests.ps1`, `script-wording-contract.Tests.ps1`.
- **Composite sibling + orphan cleanup invocation** (#548) — the session-startup skill now passes sibling worktree paths and orphan branch names as parameters to a single `post-merge-cleanup.ps1 -SiblingWorktrees @(...) -OrphanBranches @(...)` invocation, so confirming the full cleanup batch triggers one permission prompt instead of one per branch.

### Changed

- **`skills/session-startup/scripts/session-startup-git-helpers.ps1`** (#598) — `Test-OrphanBranchCommitsAbsorbed` switched from `git log --first-parent` to `git rev-list ... --no-merges` + `git log --no-merges --name-status`. Closes a recall gap where sub-feature-merge topologies (feature branches that absorbed a sub-feature via `git merge --no-ff`) hit the empty-path guard and conservatively declined auto-resolve. Second-parent ancestors now appear in both `$residualSHAs` and `$commitPaths` with their actual file paths. Added a `# SAFETY ASSUMPTION (workflow-dependent):` inline comment documenting the squash-merge + headRefOid coupling and the escalation path (issue #599) if the project's merge convention ever broadens.
- **`skills/session-startup/SKILL.md`** (#596) — race-condition wording updated from `'became unmerged between re-check and force-delete'` to `'branch not reachable from default (merged-state re-check returned false)'` for accuracy.

### Fixed

- **Polish nits from PR #595 adversarial review** (#596) — minor wording fixes (M10/M11/M16/M17), shim call-log assertion for `--base master` in the master-default-branch test, and Pester `-Because` text alignment with the new race-condition wording.

## [2.16.0] — 2026-05-19

### Added

- **`skills/solution-authoring/SKILL.md`** — new cognitive-surrender-prevention v0 engagement skill. Codifies the D-classification-test (3-leg gate with artifact-citation falsifier), decision brief structure, override semantics, skip rules (including engineer-declined-engagement and same-decision-resume stub for #575), thin-articulation criterion with forward-compatible YAML schema, and 5 template sections each with a canonical exemplar from the #571 R1+R2 transcript. Declares no `provides:` field — supporting methodology, not a frame port adapter.
- **`skills/solution-authoring/platforms/claude.md`** and **`skills/solution-authoring/platforms/copilot.md`** — platform-specific AskUserQuestion / vscode/askQuestions invocation notes.
- **`Documents/Design/frame-architecture.md`** — stacking-precedent paragraph in the Adapter Model / Declaration asymmetry section documenting that `solution-authoring` and `upstream-onboarding` can stack as `provides:`-less supporting methodologies with load-order declared in the agent body dispatcher.
- **`.github/scripts/Tests/solution-authoring.Tests.ps1`** — structural Pester contract covering AC11.a–AC11.g: body shape (5 rule + 5 template sections), platforms parity, 4-body directive (new present, old absent, line-index ordering, CC touchpoint enumeration), upstream-onboarding sweep (no "first" in 3 anchors + allowlist gate), recommendation-shift token, v0 gate comment, terminology drift guard.

### Changed

- **`agents/Experience-Owner.agent.md`**, **`agents/Solution-Designer.agent.md`**, **`agents/Issue-Planner.agent.md`**, **`agents/Code-Conductor.agent.md`** — `## Process` section standalone upstream-onboarding load line replaced with two-sentence solution-authoring-first directive plus cross-session disclaimer (tracked in #575). Code-Conductor additionally enumerates `scope-classification` and `D9-checkpoint` as content-authoring touchpoints.
- **`skills/upstream-onboarding/SKILL.md`** — removed "first" load-order claim at three section-anchors (frontmatter description, ## When to Use opener, ### Sequencing bullet). Added `<!-- d-load-order-resolution-anchor -->` near ## When to Use. The skill no longer asserts it must be loaded first; that ordering is declared in each agent body dispatcher.

## [2.15.1] — 2026-05-18

### Added

- **Plan tree-state verification discipline** (#582 / issue #579) — Issue-Planner now runs a tree-state verification before adversarial stress-test invocation and populates a `**Verification Evidence**` block in the plan. Includes new `.github/scripts/plan-tree-state-verification.ps1` and Pester contract tests under `.github/scripts/Tests/`.
