# Changelog

All notable changes to agent-orchestra will be documented in this file.

## [2.35.14] — 2026-06-29

### Added

- **Reporting-economy directive across specialist bodies** (#471): canonical reporting-economy bullet added as the terminal `## Core Principles` bullet in all 11 dispatched specialist agent bodies (Code-Critic, Code-Review-Response, Code-Smith, Doc-Keeper, Process-Review, Refactor-Specialist, Research-Agent, Senior-Engineer, Specification, Test-Writer, UI-Iterator). Bans tool-call transcript echo (load-bearing for frozen Copilot path); caps free narration at ~150 words, subordinate to any role-mandated structured artifact, with a carve-out for fixed-form output (Step 0 / ND-2 / parity-locked literals). Parent override preserved.
  - **`reporting-economy.Tests.ps1`**: discovery-based Pester test (glob `agents/*.agent.md` minus 5 pinned exclusions = 11 in-scope); count guard (==11 in-scope, ==5 excluded); terminal-bullet anchor; `BeforeDiscovery` parameterization; reuses parity helpers `GetSectionBody` / `NormalizeContent`.
  - **`reporting-economy-spotcheck.ps1`**: behavioral spot-check analyzer; reads `attributionAgent` from each subagent's final-report assistant event at `{SlugDir}/subagents/agent-{id}.jsonl`; emits per-dispatch word count, echo-detected, and override-flag; explicit baseline-unavailable signal when no transcripts found.
  - **`reporting-economy-spotcheck.Tests.ps1`**: 19 Pester unit tests for the production parser (attributionAgent parsing, last-event selection, out-of-scope exclusion, word count across single and multi-block content, echo detection, override flag with false-positive guard, missing attributionAgent, ToolUseId derivation, baseline-unavailable, nested session-dir record collection). Tests dot-source the production `Get-SpotcheckRecord` / `Invoke-ReportingEconomySpotcheck` functions via `-ImportMode` and use the real subagent JSONL schema — in-process invocation per the #257 script-safety contract (no child-pwsh spawn).

## [2.35.13] — 2026-06-29

### Fixed

- **Cost telemetry v4 emission reliability** (#769): deterministic fail-loud v4 emission path wired end-to-end into Code-Conductor.
  - **`lib/Get-FCLOriginContext.ps1`**: new CI-safe orchestrated-origin predicate using `$env:GITHUB_HEAD_REF` (primary) and PR body linked-issue signals (fallback). Excludes detached-HEAD `HEAD` literal (M3 bug fix). Returns `IsOrchestratedOrigin`, `LinkedIssueNumber`, `DetectionMethod`.
  - **`emit-pipeline-metrics-v4.ps1`**: deterministic 3-case fail-loud emitter — builder-throw → `<!-- cost-capture-failed -->` sentinel; empty credits → sentinel; success → v4 block. Called before `gh pr create` in Code-Conductor's fresh-PR path; push-only path explicitly exempted. Non-zero exit on failure.
  - **`lib/Add-FCLCreditRow.ps1` / `lib/Get-FCLAccumulatedCredits.ps1`**: file-based credit accumulator at `.tmp/issue-{N}/fclcredits.jsonl`; harvest hook in emit script ensures credits are non-empty on orchestrated runs. Conductor body gains `Add-FCLCreditRow` call after each `Build-*CreditRow` step.
  - **`frame-credit-ledger.ps1`**: origin-gated 3-state taxonomy (`🛑 FAILED` / `not measured (non-orchestrated)` / `pre-v4`) at each short-circuit site; off-switch via `FCL_SUPPRESS_FAILED_POSTS` env var.
  - **`.github/workflows/cost-pattern-presence-check.yml`**: widened `if:` to include `startsWith(github.head_ref, 'feature/issue-')` head refs; step now checks PR body for `<!-- pipeline-metrics` instead of PR comments for `<!-- cost-pattern-data`.

## [2.35.12] — 2026-06-29

### Added

- **Phase-containment escape-rate ledger** (#762, review-efficacy sub-1): instrumentation that measures how far review-pipeline defects escape from the phase where they were catchable.
  - New schema `skills/calibration-pipeline/schemas/phase-containment.schema.json` — 10-field JSON Schema (draft-07) for `<!-- phase-containment-{ID} -->` YAML blocks.
  - New `.github/scripts/lib/phase-containment-core.ps1` — hand-rolled (powershell-yaml-free) parser/validator: `Get-PhaseContainmentBlock` (multi-block), `ConvertFrom-PhaseContainmentYaml`, `Test-PhaseContainmentEntry`, `Get-PhaseContainmentFindingKey`, `Get-PhaseContainmentEnumDriftStatus`.
  - New `.github/scripts/lib/phase-containment-rolling-history-core.ps1` — two-surface walk (issue + merged-PR comments), 1-hour two-sided cache, GraphQL→REST fallback, dedup-by-finding_key, and `Get-PhaseContainmentRollup` (InsufficientData / DenominatorZero / DataUntrustworthy guards, RelaxationEligible signal, leakage matrix).
  - New CLI `.github/scripts/phase-containment-report.ps1` — per-stage CE Gate report with INSUFFICIENT DATA / DATA UNTRUSTWORTHY / NOT ELIGIBLE / ELIGIBLE labels.
  - Wired phase-containment emission into `skills/design-exploration`, `skills/plan-authoring`, and `skills/review-judgment` with setter rules and detective-sample audit.
  - CE Gate verification `.github/scripts/Tests/Invoke-CEGate762.ps1` (AC3/AC4/AC8/AC12) plus Pester coverage in `phase-containment-core.Tests.ps1` (25) and `phase-containment-rolling-history-core.Tests.ps1` (24).

## [2.35.11] — 2026-06-28

### Added

- **Dispatch-prompt economy** (#472): added a dispatch-prompt economy rule to Code-Conductor Step 3 ("Execute Each Step") directing the conductor to reference the canonical plan source (`Read <!-- plan-issue-N --> step M for contract`) instead of re-inlining contract detail in specialist dispatch prompts; novel constraints not already in the plan/design always stay inline.
  - New design doc `Documents/Design/dispatch-prompt-economy.md` — rule placement, scope (C2.a delivered; C2.b prepared-payload and M1 telemetry-proof deferred), and a before/after lean dispatch example.
  - New `skills/parallel-execution/references/lean-dispatch-example.md` — canonical lean before/after dispatch example, indexed in the skill's Composite References.

## [2.35.10] — 2026-06-28

### Added

Add ## Grounding Discipline section to skills/design-exploration/SKILL.md — four-quadrant pre-challenge artifact trace gate (Q1 output->consumer, Q2 input->exec-env, Q3 current-behavior, Q4 premise-citation) with timing split, disposition enum, **Grounding Evidence** block, and 60 KB guard. Wire **grounding gate** forcing-function into agents/Solution-Designer.agent.md between Stage 2 and Stage 3. Add 5th Issue-Planner-lens backstop row to skills/upstream-onboarding/SKILL.md. Add Pester structural test design-grounding-discipline.Tests.ps1 (14 tests). Closes #763.

## [2.35.9] — 2026-06-28

### Added

- **De-opaque living reader surfaces** (#750): applied #732 two-register naming policy to always-on entry points.
  - Replaced "Value Reflex" with "worth-it check" at 3 prose locations (CLAUDE.md, HOW-IT-WORKS.md §2/§4); vocab-seed block and `## Value Reflex (First Beat)` heading in experience-owner.md preserved.
  - Added stable `<a id="vocab"></a>` anchor in HOW-IT-WORKS.md §5 (renumber-safe; survives #696 ToC sweep). Added `<!-- vocab-pointer -->` escape-hatch footer on 9 living surfaces: CLAUDE.md, skills/README.md, CUSTOMIZATION.md, 6 Documents/Design orientation docs.
  - Added first-use inline expansions in CLAUDE.md: SMC-01 → "SMC-01 (Session Memory Contract marker)"; CE Gate → "CE Gate (Customer Experience Gate)".
  - Created minimal `.github/ISSUE_TEMPLATE/bug_report.md`, `.github/ISSUE_TEMPLATE/feature_request.md`, and `.github/PULL_REQUEST_TEMPLATE.md` — bare-structure templates each carrying the vocab-pointer footer.
  - Fixed `skills/README.md`: count 47 → 53; added 6 missing rows (ai-first-documentation, engagement-record-emission, naming-register-policy, persist-changes, project-references, solution-authoring) using existing `description:` frontmatter verbatim.
  - New bounded Pester guard `.github/scripts/Tests/NamingRegisterLivingSurface.Tests.ps1`: term-absence (with vocab-seed block exclusion), pointer-presence, anchor-uniqueness, file-existence assertions over the enumerated in-scope surface set.

## [2.35.8] — 2026-06-27

### Changed

- **Control Tower v2 documentation + intake rule** (#753, s7): documented the ranked-umbrella portfolio board that shipped in #756. The board's zones changed from the v1 "Now / Next / Blocked / Recently closed / Triage" lane model to **🎯 Active** (first open umbrella, expanded) / **Umbrellas (ranked)** / **🔥 Triage** (derived) / **Recently closed**.
  - New design doc `Documents/Design/control-tower-v2.md` — schema_version 2 spec, three-zone derivation, drift/integrity warn tiers, idempotent splice, and the #746 connection-cap dependency.
  - `skills/safe-operations/SKILL.md` §2b-bis rewritten for v2: new umbrellas must be inserted into `Documents/Planning/sequence.yaml`'s `umbrellas:` list at the correct rank (canonical home, no routing-tables entry); Triage is now **auto-derived** from parent-edge data, so `--label triage` is optional/advisory rather than load-bearing.
  - `skills/post-pr-review/SKILL.md` cross-reference to the new design doc.

## [2.35.7] — 2026-06-27

### Added

Add skills/naming-register-policy/ — two-register naming policy skill, 48-entry vocab-seed register, Pester test suite with CI wiring (issue #732)

## [2.35.6] — 2026-06-26

### Added

- **HOW-IT-WORKS.md orientation doc** (#749): new plain-language orientation document at the repo root. Five sections: what Agent Orchestra is, the work pipeline (board to merged PR), how to read an issue/PR, optional depth (`<details>` blocks), and a 48-row vocabulary table (seeds the #732 naming/register policy via the `<!-- vocab-seed:begin/end -->` anchor). README pointer added after deprecation banner. `.markdownlint.json` now allows `<details>` and `<summary>` HTML elements (MD033).

## [2.35.5] — 2026-06-26

### Fixed

- **BDD enablement detection now requires a `^## BDD Framework` line-start heading (column 0)** (#733): replaced substring/presence phrasing across 13 agent-and-skill detection sites in `agents/Experience-Owner.agent.md`, `agents/Issue-Planner.agent.md`, `agents/Test-Writer.agent.md`, `skills/bdd-scenarios/SKILL.md`, and `skills/customer-experience/references/orchestration-protocol.md`; anchored 12 detection references in `Documents/Design/bdd-framework.md`. Added **Discriminator** note with `grep -nE '^## BDD Framework'` oracle. The hub's own `copilot-instructions.md:33` backtick mention no longer produces a false positive under anchored detection.

## [2.35.4] — 2026-06-26

### Fixed

- **Canonical pipeline-metrics v4 emission from Code-Conductor inline PR creation** (#739): fixes the integration seam where `Build-*CreditRow` outputs (`[pscustomobject]`) were rejected by `New-PipelineMetricsV4Block` (declared `[hashtable[]]`), breaking the entire v4 emission path and short-circuiting the frame credit ledger to the pre-v4 path. Additional fixes: `Escape-FCLScalar` now uses YAML `""` escaping (not `\"`), both `Get-FCLScalar` and `ConvertFrom-FCLListSection` unescape `""` → `"` on read-back (round-trip losslessness AC1), `Test-PipelineMetricsV4Block` stripped of repair-loop logic (pure warn-only per #429), v3-base `-->` injection escaping, guard regex anchored.
- **Atomic CHANGELOG insertion in `bump-version.ps1`** (#739 s5): extracted `Invoke-ChangelogInsertion` into `changelog-insert-core.ps1` (idempotency check, separator-agnostic anchor, read-back verify, no file I/O); `bump-version.ps1` now wires `-ChangelogEntry`/`-ChangelogSection` parameters with verify-before-write guard.

## [2.35.3] — 2026-06-26

### Added

- **File-granular parallel sharded Pester runner** (#740): new `.github/scripts/run-pester-sharded.ps1` thin wrapper + `.github/scripts/lib/pester-sharded-core.ps1` logic library (per the #257 lib+thin-wrapper convention). Discovers all `.Tests.ps1` files, splits a parallel shard (`ForEach-Object -Parallel -ThrottleLimit 8`) from a sequential real-git shard (`plugin-release-hygiene`, `session-cleanup-detector` — keyed on actual `git init`/`git commit` fixture behavior, not string grep), and enforces a no-false-GREEN contract: a missing result file (crashed worker) **or** a file that discovers zero tests is a hard failure with non-zero exit. Includes a `-DeterminismCheck` mode that runs the suite twice and fails on any per-file pass/fail flip. The real-git shard pins a temp `GIT_CONFIG_GLOBAL` (user identity + `commit.gpgsign=false` + `init.defaultBranch=main`) without pre-setting `GIT_TERMINAL_PROMPT`/`GCM_INTERACTIVE`/`GIT_ASKPASS` (those stay owned by the scripts under test).
- **Pester suite performance audit** (`Documents/Design/pester-suite-performance-audit.md`): per-It timing profile of the top-3 slowest files, full spawn-form inventory with CONVERTIBLE/IRREDUCIBLE verdicts, and the CE Gate result with theoretical-floor analysis.

### Changed

- **Per-test `pwsh` spawns converted to in-process dot-source** (#740): 20 content `It` blocks in `frame-credit-ledger-orchestrator.Tests.ps1` (321s → 70s) and 8 in `cost-integration.Tests.ps1` (98.6s → 7.7s) now dot-source the orchestrator and stub `git`/`gh` in-process instead of spawning a child process per test. Exit-code-contract and timing-contract Its are preserved as a real-spawn smoke layer. Full suite wall-clock: ~836s → 238s (3.5× speedup); the ≤120s target remains gated by an irreducible ~124s floor (see audit doc).
- **Spawn guard upgraded to AST scan** (`script-safety-contract.Tests.ps1`): replaced the `& pwsh` string-grep with a `[Parser]::ParseFile()` + `CommandAst` scan that detects both `& pwsh`/`& powershell` and `Start-Process -FilePath 'pwsh'` forms without false-positives on string literals; added two falsifiability Its and expanded the IRREDUCIBLE allowlist (same-commit atomic with the scan change).

### Fixed

- **Pre-existing `composite-skill-structure` red** (#740): trimmed `skills/code-review-intake/SKILL.md` from 88 to 79 lines to satisfy the ≤80-line composite-skill contract, with no information loss (covered by retained body sections).

## [2.35.2] — 2026-06-26

### Changed

- **CLAUDE.md diet — extracted four blocks to their owning sources** (#694): trimmed `CLAUDE.md` from ~270 to 189 lines (below the <190 target and the <200 A2 audit budget) by moving four duplicated content blocks to their canonical homes without information loss — the cross-tool handoff marker catalog → new `skills/session-memory-contract/references/handoff-markers.md` (13 active + 1 retired families); the deferrable Intent Routing mechanics (rules 1,2,3,5,9,10) → `skills/routing-tables/SKILL.md § Intent Routing Mechanics`; the auto-mode boundary verification recipe → `skills/session-startup/SKILL.md` (sentinel-wrapped); and the full per-agent model + reasoning routing table → `Documents/Design/agent-body-architecture.md`. The four CLAUDE.md keep-set routing rules (4, 6, 7, 8) and all four section stubs with resolving pointers remain.

### Fixed

- **Per-agent routing parity claim and moved-recipe link drift** (#694 adversarial review CR1/CR2/CR4): struck the now-false "routing-table parity" enforcement claim from `agent-body-architecture.md` and added the authoritative-source-is-frontmatter note; repaired two dead relative links in the relocated auto-mode recipe (`skills/session-startup/SKILL.md`) and hardened `auto-mode-boundary.Tests.ps1` test 7 to resolve recipe links against the recipe file's own directory instead of the repo root; updated a stale `.DESCRIPTION` docstring in `per-agent-model-routing.Tests.ps1`.
- **Gemini Code Assist review** (#694 PR #738): case-insensitive `-replace` for repo-root stripping in `per-agent-model-routing.Tests.ps1`, `@(Get-Content)` array-wrap for the diet line count, and a `#when-to-skip` anchor on the upstream-onboarding recipe link.

### Tests

- New `claudemd-diet.Tests.ps1` (5 tests): the <200-line diet guard plus pointer-resolution sentinels for all four extraction destinations. `per-agent-model-routing.Tests.ps1`, `auto-mode-boundary.Tests.ps1`, and `orchestra-spine-command.Tests.ps1` pivoted to read the relocated content from its new homes; `audit-docs-mechanical.Tests.ps1` AC9 flipped to assert the hub `CLAUDE.md` now passes the A2 budget check. Added a `.github/prompts/*.prompt.md` entry to `Documents/Design/hub-artifact-paths-classification.yml` — the Intent Routing extraction surfaced that Copilot-prompt path family into a scanned scope (`skills/*/SKILL.md`), which the hub-artifact-paths coverage gate requires classified.

## [2.35.1] — 2026-06-26

### Added

- **Ledger-vs-Validation Boundary guardrail** (`skills/code-review-intake/SKILL.md`, `Documents/Design/code-review.md`): a normative `### Ledger-vs-Validation Boundary` section plus a Gotchas row establishing that GitHub review ingestion and ledger-building (steps 1–2) are strictly mechanical — the conductor records each ingested finding verbatim and maps it to its comment/review ID, and MUST NOT accept, reject, or form any per-finding correctness verdict before proxy prosecution runs. Per-finding validation is the proxy prosecution pass's responsibility (step 3); the sole pre-prosecution conductor-side correctness call permitted is `NEW-CRITICAL` for a newly discovered blocker, not an ingested finding. Protects adversarial independence: the conductor also owns the ledger build, accepted-fix dispatch (R4), and judge dispatch, so a correctness opinion formed during ingestion would bias those downstream steps (#735).

## [2.35.0] — 2026-06-24

### Fixed

- **Full Pester suite restored to clean green** (#723; absorbs #566 local-Windows triage): 26 pre-existing failures across ~17 subsystems root-caused and fixed. Highlights: a real regression in `skills/session-startup/scripts/post-merge-cleanup.ps1` (#727 hoisted `Resolve-Path` out of a loop, crashing `-IssueNumber` runs from any tree lacking `.copilot-tracking/`) is guarded; `frame-audit-report-core.ps1` `Get-FARBucketForCreditStatus` now warn-skips unknown live credit statuses (→ `inconclusive`) instead of throwing on `harvested-from-issue`; the `aggregate-review-scores` skip→full test no longer depends on wall-clock time (relative within-window date + `re_activated: false` assertion proving the sustain-rate path + non-vacuous clear assertion). Stale contract/parity/wording tests reconciled to match intentionally-shipped features (#439/#500/#574/#591/#620/#625/#632/#663/#706/#627) — fixed test-side only, bodies never reverted.
- **Restored S4 framing sentence lost in #632's DRY consolidation** (`skills/adversarial-review/platforms/claude.md`): the working-tree-mutation ND-2 recovery framing was dropped from the command sites without being carried into the consolidated checklist.
- **PR #731 review findings** (proxy prosecution → defense → judge): fixed a vacuous `else`-branch assertion in the `aggregate-review-scores` leave-skip writeback test (production takes the key-removal path, so the old assertion re-asserted the branch condition — now a raw-JSON check on the written calibration file, AC4); hyphenated the `Code-Conductor` handoff prose in `agents/Code-Conductor.agent.md` + `skills/session-memory-contract/references/conductor-session-handoff.md` to kill source/extract drift (SCR2); and fixed an `exercise/N-A` → `exercise/N/A` typo (SCR1).

### Added

- **Wall-clock fixture guard** (`.github/scripts/Tests/wall-clock-fixture-guard.Tests.ps1`, registered in `.github/workflows/pester.yml`): a static guard that fails when a band-asserting fixture assigns an absolute ISO-date literal to the now-coupled `skip_first_observed_at` field (line-level `# absolute on purpose` exemption), with a falsifiability self-test and a core-drift check. Makes wall-clock independence a checked CI invariant (#723). The detection regex covers both single- and double-quoted ISO literals (PR #731 GCR3, AC3).

### Changed

- **Size-lint splits via composite-skill extraction** (not threshold bumps): `agents/Code-Conductor.agent.md` 588→499 lines (verbose sub-content extracted under 21 preserved H2 headings into 5 reference files; all shell-parity + contract-asserted text preserved), `skills/customer-experience/SKILL.md` rebalanced to ≤80 lines after the #729 Value Reflex merge by extracting the Value Reflex outcome contract and the Hub/Consumer Classification Gate into new reference files, `skills/code-review-intake/SKILL.md` 93→78 (#723).

## [2.34.0] — 2026-06-24

### Added

- **Advisory Value Reflex — worth-it check as the first beat of `/experience`** (`skills/customer-experience/SKILL.md`, `agents/Experience-Owner.agent.md`, `CLAUDE.md`): an optional, skippable check that runs once per issue before framing begins. Three prompts (Bet / Falsifier / Alternative) with no numeric score produce an advisory recommendation from five outcomes — `Proceed-full`, `Proceed-lite`, `Shrink`, `Park`, `Decline`. Advisory only: the owner decides and may proceed regardless. An accepted `Park` or `Decline` is recorded as a `worth-it-{ISSUE}` entry in the `engagement-record-experience-{ISSUE}` burst and applies a `status: parked` or `status: declined` label; `same-decision-resume` suppresses re-prompting on re-entry. `Proceed-*`/`Shrink` outcomes are not recorded. Say `frame it` to skip (#729).

### Tests

- 12 Pester structural and constant-validation `It` blocks (`.github/scripts/Tests/value-reflex.Tests.ps1`) locking the invariants: exactly three numbered prompts, the `frame it` skip affordance, the no-numeric-score guard, first-beat ordering (item 0 before item 1), the five-outcome enum, the `worth-it-{ISSUE}` recording reference, the `status: parked`/`status: declined` label-apply plus halt wiring, the `Test-EngagementRecordSlug` slug-regex contract, and the `experience` phase-enum membership (#729).

### Fixed

- **Version drift across version-bearing files** (`plugin.json`, `.claude-plugin/marketplace.json`, `.github/plugin/marketplace.json`, `README.md`): a prior release advanced only `.claude-plugin/plugin.json` to 2.33.1 while the other manifests and the README badge lagged at 2.33.0/2.32.0. This bump reconciles all seven occurrences across five files to 2.34.0 (#729).

## [2.33.1] — 2026-06-23

### Fixed

- **Session-cleanup false-positive on live persistent tracking files** (`skills/session-startup/scripts/session-startup-git-helpers.ps1`, `skills/session-startup/scripts/session-cleanup-detector-core.ps1`, `skills/session-startup/scripts/post-merge-cleanup.ps1`): root-level `.copilot-tracking/` artifacts with no `issue_id` frontmatter — `gate-events.jsonl`, `references-state.yml`, `references-init.manifest` — were flagged as stale untagged tracking files and archived by the cleanup executor. A new dual-axis exclusion registry (`Get-SCDPersistentTrackingExclusions` returning `Subtrees` + `Filenames`) is the single source of truth consumed by both detector and executor. The detector excludes registered filenames matched root-anchored at depth 0 (a registry-named file at depth ≥ 1 is still flagged); both executor archival routes skip registered files with a warning. Both consumers fail loudly (HALT + exit 1) before any `Move-Item` when the accessor is undefined or returns `$null`/missing `Filenames` — never fail-open toward deletion (#656).

### Tests

- 11 new Pester `It` blocks across two harnesses covering AC1–AC7: per-seed-file exclusion, positive companion (non-registry untagged file still flagged), over-exclusion depth guard, undefined-accessor hard-halt for both detector and executor, writer-oracle parity, and both executor-route skips (#656).

## [2.33.0] — 2026-06-22

### Added

- **Deferral discipline — ARM 2 behavioral-term AC cross-check** (`skills/review-judgment/scripts/Get-AcTermsFromIssue.ps1`, `skills/review-judgment/scripts/Test-DeferralCriteria.ps1`): a second AC cross-check arm that extracts behavioral-term identifiers from the issue's `## Acceptance Criteria` section and matches them against finding text. Behavioral terms (containing must/shall/gate/guard/etc.) route to `force-accept`; non-behavioral terms route to `disposition-gate`; no-match routes to `defer`. Confidence-tiered routing populates an `ac_cross_check` OUT object on every verdict path. Backward-compatible: `-AcTerms = @()` default leaves all existing callers unchanged (#709).

- **Blocking pre-condition and loud guard** (`skills/review-judgment/SKILL.md`): no `dismiss`/`defer` entry at severity ≥ medium may be committed without a populated `ac_cross_check`. When `routed: defer` is the result, the loud guard mandates an inline note + a sub-issue created via `Add-FollowUpIssue -AcCrossCheck` carrying AC provenance YAML (#709).

- **`schema_version: 2` per-entry fields** (`skills/solution-authoring/schemas/review-dispositions.schema.json`): adds `severity`, `stage`, and `ac_cross_check` per entry. v1 legacy entries are exempt from the `ac_cross_check` presence check. CE Gate deferrals use `stage: ce` (#709).

- **`Add-FollowUpIssue -AcCrossCheck` parameter** (`skills/safe-operations/scripts/Add-FollowUpIssue.ps1`): optional M16 guard that appends AC provenance as a YAML block to the sub-issue body. String scalars are double-quoted so colon-bearing `ac_ref` values produce valid YAML (#709).

- **ARM 2 integration in agent bodies** (`agents/Code-Conductor.agent.md`, `agents/Code-Review-Response.agent.md`, `skills/code-review-intake/SKILL.md`): `Get-AcTermsFromIssue` is called alongside `Get-AcRefsFromIssue` at the AC pre-population step; `-AcTerms` is passed to `Get-StructuralVerdict` (#709).

### Fixed

- `disposition: defer` was absent from the `review-dispositions` schema enum and validator accept-list despite being written by SKILL.md's loud-guard path (#709/F1).
- Phantom `minor` severity tier removed from schema and validator threshold; all prose updated from "≥ minor" to "≥ medium" to match the canonical producer enum in `routing-config.json` (#709/F2).

### Tests

- 27-test suite for `Get-AcTermsFromIssue` covering constants, extraction, behavioral detection, stop-list, H2 boundary, dedup, and failure paths.
- 18-test suite for `Test-DeferralCriteria` covering ARM 1+2 routing, backward compat, and `ac_cross_check` population.
- 25-test integration suite for the full deferral path including F5 YAML-quoting regression and F7 integrated `routed: defer` → mandatory sub-issue call (#709).

## [2.32.0] — 2026-06-21

### Changed

- **Five-pass two-layer prosecution panel for the `standard` adversarial-review adapter** (`skills/adversarial-review/platforms/claude.md`, `skills/adversarial-review/adapters/standard.md`, `skills/adversarial-review/SKILL.md`, `agents/Code-Critic.agent.md`): replaces the homogeneous 3× Opus prosecution with a diverse panel — `generalist-A` (Sonnet), `generalist-B` (Opus), and three Opus specialists (`spec-correctness`, `spec-security`, `spec-architecture`). Cross-layer dedup merges on failure-mode + code-location and prefers the deepest-tier finding (Opus over Sonnet); the panel survives iff ≥1 generalist **and** ≥1 specialist clear quorum after per-pass retries. PR-phase prosecution-pass enums widen `[1,2,3]` → `[1,2,3,4,5]` across the schema, validator, routing-config, metrics schemas, and supporting prose; the design-phase `design-disposition-audit` `[1,2,3]` invariant is unchanged. Adds an optional `model:` field to `dispatch-cost-samples[]`, wired end-to-end (parser positional contract, RC back-fill preservation, merge dedup key, round-trip tests). Also folds in the inline doc corrections that AC4's surface sweep promised (`Documents/Design/frame-architecture.md`, `skills/review-judgment/SKILL.md`, `skills/calibration-pipeline/references/metrics-schema.md`) and a quorum "well-formed ledger" definition clarification (#706, with inline fixes for #714/#716/#717/#718).

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
