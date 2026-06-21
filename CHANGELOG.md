# Changelog

All notable changes to agent-orchestra will be documented in this file.

## [2.31.0] — 2026-06-21

### Added

- **CI release gate** (`.github/scripts/lib/release-gate-core.ps1`, `.github/scripts/release-gate.ps1`, `.github/workflows/release-gate.yml`): A required PR check that fails any PR touching plugin entry points (`agents/**`, `commands/**`, `skills/**`, `hooks/**`, `.claude-plugin/**`, `plugin.json`, `README.md`, `.github/copilot-instructions.md`) without a monotonic version bump **and** a matching `## [version]` CHANGELOG section. Leg-scoped `Skip-Release-Check:` commit-trailer waiver: `changelog-only` waives only the CHANGELOG leg; `all <reason>` waives both. Fail-closed on any base-ref/diff error (AC5). Entry-point membership delegated to `Get-FVPluginEntryPointPatterns`; parity enforced by `.github/scripts/Tests/entry-point-scope-parity.Tests.ps1` (#703).

## [2.30.0] — 2026-06-12

### Added

- **Derived portfolio tracker** (`Documents/Planning/sequence.yaml`, `.github/scripts/render-portfolio.ps1`, `.github/scripts/Tests/render-portfolio.Tests.ps1`, `.github/workflows/render-portfolio.yml`): a merge-triggered control-tower renderer that derives a five-bucket portfolio (Now / Next / Blocked / Recently closed / Triage) from a truly-flat sequence spec and the live GitHub issue graph (`blockedBy` dependencies), then idempotently splices it into the control-tower issue body. Includes the `render-portfolio.yml` push/`workflow_dispatch` workflow (SHA-pinned checkout, `persist-credentials: false`, `gh`-only auth), a 20-test Pester suite registered in the CI gate, and three skill touchpoints — `safe-operations` §2b-bis umbrella/triage intake, `post-pr-review` §7 auto-render note, and `session-startup` Step 7c portfolio snapshot (#692).

### Changed

- Version bumped to 2.30.0 (2.29.0 was concurrently claimed by #708's ai-first-documentation consumer-mode release; this entry resolves the collision).

## [2.29.0] — 2026-06-12

### Added

- **`/audit-docs` command and mechanical-check script** (`commands/audit-docs.md`, `skills/ai-first-documentation/scripts/audit-docs-mechanical.ps1`, `skills/ai-first-documentation/templates/CLAUDE.md-starter.md`): Consumer-mode enablement for the `ai-first-documentation` skill. The `/audit-docs` command runs deterministic mechanical checks (A2, B2, B3, B5, A9) against any consumer repository with explicit `-Root`, emits JSON results, and supports a waiver convention via `.claude/documentation-decisions.md`. An `init` action bootstraps a minimal CLAUDE.md starter template. Includes a routing row (`intent_key: audit-docs`, audit-anchored patterns) and collision fixtures. SKILL.md updated with `## Consumer-Mode Audits` and `## Recording Documentation Decisions` sections including the H3-per-record decision-record format and CI acquisition guidance (#699).

## [2.28.0] — 2026-06-12

### Added

- **Plan-authoring Grounding Pass** (`skills/plan-authoring/SKILL.md`): a new `### 4. Grounding Pass` discipline in the Discovery Workflow that establishes the invariant "no plan step may name an ungrounded artifact." Before drafting, the planner verifies that every artifact a plan step names (file names, paths, exported symbols, shapes, counts) actually exists in the tree and corrects or updates the issue when it does not. Adds a `#591` migration-scan carve-out, a `#467` per-port observation note, a Research Subagent contradiction-reporting directive, a factual-correction exemption in the Alignment Workflow (factual corrections are not "material scope changes" that trigger loop-back), and a reciprocal cross-reference with the post-draft Tree-State Verification Discipline. Locked by the RED assertion-existence contract `.github/scripts/Tests/plan-authoring-grounding-pass.Tests.ps1` (#473).
- **Issue drift scan on pickup** (`skills/upstream-onboarding/scripts/get-issue-drift-core.ps1`, `skills/upstream-onboarding/scripts/get-issue-drift.ps1`): deterministic PowerShell library + wrapper that scans merged PRs since an issue was created and returns path-matched candidates as JSON. Age-gated at 7 days (bypassed with `-Force`); DI-injectable via `-IssueJsonOverride`/`-PrListJsonOverride` for Pester testing without live `gh` calls. Three output shapes: `{skipped:"below-threshold"}`, `{error:"..."}`, and full result with ranked `candidates[]`. Handles `.files[].path` object arrays, per-PR `files_truncated`, 200-row truncation detection, `ExcludePaths` filtering, cap + `more_count`, and intersection-none fallback (#683).
- **Pester coverage for drift scan** (`.github/scripts/Tests/get-issue-drift.Tests.ps1`): 20 tests covering age-gate boundary, date boundary, offset robustness, 200-row truncation, `#591`-shaped token extraction, `ExcludePaths` override and default, cap + `more_count`, all three output shapes, intersection:none, `files_truncated`, guarded numeric parsing, and case-insensitive path matching (#683).

### Changed

- **`upstream-onboarding` drift section** (`skills/upstream-onboarding/SKILL.md`): new `### Changed since this issue was filed` conditional section surfaces the drift script output as a ranked candidate list (format: `#N — title (touches: paths)`) with count-only fallback when intersection is none, truncation note, and ephemerality rule. On-Demand Expand extended with "what changed"/"what's changed"/"what happened since" trigger phrases and error surfacing. Resume Variant narrow exception documents that the drift section may appear on same-agent resume. Third affordance-hint predicate added for drift threshold (#683).
- **Claude Code platform notes** (`skills/upstream-onboarding/platforms/claude.md`): `## Drift scan — script path resolution` section documents the D1 plugin-cache-priority path-resolution sequence (repo clone first, then plugin-cache `installPath` lookup, then emit `couldn't check: script not found`) (#683).
- **Copilot platform notes** (`skills/upstream-onboarding/platforms/copilot.md`): equivalent drift scan path-resolution section for VS Code plugin-cache (#683).

## [2.27.0] — 2026-06-11

### Added

- **`ai-first-documentation` skill** (`skills/ai-first-documentation/`): research-backed documentation standards skill for authoring docs optimized for AI-agent consumption (#686).

## [2.26.0] — 2026-06-10

### Added

- **Git-portable `persist-changes` skill** (`skills/persist-changes/SKILL.md`, `skills/persist-changes/scripts/Resolve-PersistDecision.ps1`): caller-parameterized commit+push primitive with a side-effect-free decision helper (`Resolve-PersistDecision`) and Pester coverage. Stages only caller-supplied fix files (never `git add -A`), runs format-before-commit, commits, and conditionally pushes with guards for detached HEAD, dynamic default-branch resolution, commit-policy opt-out, fork/no-write, and non-fast-forward. Returns commit/push outcomes with explicit not-pushed reasons (#679).
- **`/review-github` response-loop completion** (`skills/code-review-intake/SKILL.md`, `commands/review-github.md`): a bare `/review-github` now closes the full loop — after judgment and routing, accepted fixes are implemented, post-fix prosecution and CE Gate run, then `persist-changes` fires as the terminal step to commit and push to the existing PR branch (or surface a loud not-pushed reason). The Response Summary commit/push/reporting contract is single-sourced in `skills/validation-methodology/references/review-reconciliation.md § Response Commit & Push` (#679).

## [2.25.2] — 2026-06-09

### Changed

- **Fat-skills consolidation for the `implement-code` port** (`skills/implementation-discipline/SKILL.md`, `skills/implementation-discipline/adapters/implement-code-adapter.md`): migrated three adapter-only behaviors (scope-discipline standard, `scope-violation` halt trigger, `simplicity-violation` halt trigger) from the adapter into the skill, then slimmed `implement-code-adapter.md` from 123 to 52 lines into a thin port-binding that names the skill as execution authority. The Halt-Return shape and reason enum stay single-sourced in `agents/Senior-Engineer.agent.md § Halt-Return Contract`. Code-Smith reads only the skill (design D0), so the port-specific triggers must live there. Code-Smith `## Core Principles` annotated as intentional persona voice pending shell retirement (#669, capstone #671, umbrella #662).

## [2.25.0] — 2026-06-07

### Added

- **Work adapters for `implement-test` and `implement-docs` frame ports** (`skills/test-driven-development/adapters/implement-test-adapter.md`, `skills/documentation-finalization/adapters/implement-docs-adapter.md`): thin Senior-Engineer work adapters enabling `/spine-run` to execute test-authoring and documentation slices end-to-end without requiring specialist-agent dispatch (#612).
- **Fat-skills extraction for documentation maintenance** (`skills/documentation-finalization/SKILL.md`): Documentation Maintenance Responsibilities methodology (CHANGELOG/NEXT-STEPS/QUICK-START/ROADMAP/Documents/Decisions with before-merge timing semantics) moved from `agents/Doc-Keeper.agent.md` body into the skill as the single source of truth (#612). Agent body now holds a heading-preserving pointer; bijection contract preserved.

## [2.24.0] — 2026-06-06

### Changed

- GitHub Copilot / VS Code support frozen as of this release — present but unmaintained, retiring after 2026-08-31. Claude Code is the only actively supported platform.
- Added internal deprecation banners to README.md, CLAUDE.md, and `.github/copilot-instructions.md`.
- Added `Documents/Design/copilot-deprecation.md` with the full freeze policy, reach-out channel (GitHub Discussions), and reversibility notes.
- De-obligated cross-platform Pester test assertions so new Claude-only work no longer requires Copilot counterparts.
- Bumped the orchestration tier from `sonnet + medium` to `sonnet + high` for `/orchestrate`, `/code-conductor`, `/review-github`, and `agents/code-conductor.md` — orchestration and review-reconciliation benefit from extended reasoning on the cost-efficient Sonnet tier. The adversarial review pass is unchanged (Code-Critic/Code-Review-Response remain on opus).

## [2.21.1] — 2026-05-31

### Changed

- **CE Gate read-gate re-point** (`skills/customer-experience/SKILL.md`): the orchestration-phase engagement-record dual-surface read gate now references `#571` instead of `#578` (`gated on #571. Until #571 merges`), aligning the skill with the umbrella that owns CE Gate dual-surface read enablement (#578).

### Added

- **Cognitive-surrender-prevention exercise procedure** (`Documents/Design/cognitive-surrender-prevention-exercise.md`): new maintainer verification procedure proving the cognitive-surrender prevention machinery (S2/S4/S5/S6) holds across sessions using falsifiable, durable evidence (#578).

### Note

- Patch bump invalidates the Claude Code plugin cache so consumers on 2.21.0 pick up the `customer-experience` skill edit (entry-point file change per release-hygiene).

## [2.21.0] — 2026-05-29

### Added

- **Resume-variant orientation snapshot** (`skills/upstream-onboarding/SKILL.md` `### Resume Variant`): a terse ~4-6 line inline snapshot renders on same-agent resume instead of the standards check (the full brief already skips on same-agent resume), assembled from already-loaded context (durable phase markers + engagement-record decisions). Cuts the flow-break of opening GitHub at pickup/resume (#633).
- **Code-Conductor smart-resume render** (`agents/Code-Conductor.agent.md` `### Hub Mode & Smart Resume`): the conductor independently authors and renders the resume-variant snapshot on marker detection before continuing (experience-complete / design-complete / plan-found paths), without delegating to the skipped upstream agent.
- **On-demand expand (D4)**: typing "expand" or "full picture" triggers a richer in-turn context summary; not registered in `nl_intent_routing`; not suppressed by `/raw`.
- **Affordance-hint predicate (D5)**: a one-line expand hint appears only when ≥1 prior engagement-record decision exists on the issue.
- **Missing-record fallback**: when no engagement-record exists on a real issue, the last-decision field renders exactly `last decision: not recorded` (never blank or fabricated).
- **Structural Pester guard** (`.github/scripts/Tests/upstream-onboarding-resume-variant.Tests.ps1`): locks the resume-variant contract at both render sites (SKILL.md and Code-Conductor.agent.md) including the standards-check-not-re-fired regression guard.

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
