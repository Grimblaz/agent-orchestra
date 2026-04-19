# Sweep Ledger — Issue #367 Path Migration

**Status**: Temporary. **Deleted in Step 15** (plan F1.8).
**Purpose**: Authoritative list of every file touched by the `.github/(agents|skills)` → `(agents|skills)` migration, with change reason and target state (UPDATE / ALLOW-LIST / SKIP).
**Produced by**: Step 1 exhaustive grep (`\.github[\\/](agents|skills)\b`, `\$copilotRoot[\\/]\.github[\\/]skills`, `chat\.agentFilesLocations`, Load directives).
**Total scanned hits**: 82 files (from `.github/(agents|skills)` pattern) + 4 `$copilotRoot` hits + 8 `chat.agentFilesLocations` hits (overlaps collapsed below).

---

## Artifact (a) — Allow-list specification

Sweep gate (`Tests/path-migration-sweep-gate.Tests.ps1`, authored Step 2) tolerates `.github/(agents|skills)` occurrences ONLY in these patterns. By Step 12, zero occurrences outside this list.

| Pattern | Reason |
|---|---|
| `Documents/Design/**.md` | Historical design records — preserve original-state references for provenance |
| `CUSTOMIZATION.md` lines inside the migration note block (fenced by `<!-- migration-note-begin -->` / `<!-- migration-note-end -->`, created Step 10(d)) | Verbatim settings.json keys and legacy `$copilotRoot/.github/skills/...` example for consumers upgrading |
| `examples/*/copilot-instructions.md` lines inside `<!-- legacy-path -->` / `<!-- /legacy-path -->` fences (created Step 10(a)) | Intentional old-path examples for downstream-consumer context |

D3b exemption whitelist (skills allowed to retain `#tool:`/`AskUserQuestion` in SKILL.md despite platforms/ split): `session-startup` only (Step 8 whitelist, CE Gate S3).

## Artifact (b) — Legacy-path fencing convention

HTML-comment markers:

```
<!-- legacy-path -->
... intentionally-retained old-path example ...
<!-- /legacy-path -->
```

Rule: any in-repo text outside `Documents/Design/` that contains a post-Step-12 `.github/(agents|skills)` occurrence MUST be wrapped in these markers. Sweep gate checks fence balance (open/close count match) and only tolerates matches inside fenced regions.

Migration-note fence for CUSTOMIZATION.md uses a distinct marker pair (`<!-- migration-note-begin -->` / `<!-- migration-note-end -->`) so it's grep-distinguishable from example legacy paths.

---

## UPDATE — 63 files

### Agents (14) — Step 5 (Load directives + plain `.github/skills` prose)

| File | Notes |
|---|---|
| `.github/agents/Code-Conductor.agent.md` | Step 5: lines 134, 163, 260, 269, 283, 291, 311, 315, 319, 327, 335, 353, 362, 397, 420, 458, 460, 462, 478, 492, 498, 560, 743, 778 + Load directives throughout. **Step 6**: line 143 (ONLY `$copilotRoot` hit; line 778 is plain prose, step-5 territory per plan F-correction) |
| `.github/agents/Issue-Planner.agent.md` | Step 5 |
| `.github/agents/Solution-Designer.agent.md` | Step 5 |
| `.github/agents/Experience-Owner.agent.md` | Step 5 |
| `.github/agents/Process-Review.agent.md` | Step 5 + Step 10(f) skill mapping table audit |
| `.github/agents/Code-Critic.agent.md` | Step 5 |
| `.github/agents/Test-Writer.agent.md` | Step 5 |
| `.github/agents/UI-Iterator.agent.md` | Step 5 |
| `.github/agents/Specification.agent.md` | Step 5 |
| `.github/agents/Research-Agent.agent.md` | Step 5 |
| `.github/agents/Refactor-Specialist.agent.md` | Step 5 |
| `.github/agents/Doc-Keeper.agent.md` | Step 5 |
| `.github/agents/Code-Smith.agent.md` | Step 5 |
| `.github/agents/Code-Review-Response.agent.md` | Step 5 |

### Skills — SKILL.md + README (7) — Step 5/6/8

| File | Notes |
|---|---|
| `.github/skills/validation-methodology/SKILL.md` | Step 5 |
| `.github/skills/tracking-format/SKILL.md` | Step 5 |
| `.github/skills/terminal-hygiene/SKILL.md` | Step 5 |
| `.github/skills/session-startup/SKILL.md` | **Step 6**: line 52 `$copilotRoot/.github/skills` + Step 8 coupled-split lane (D3b exempt — SKILL.md retains methodology) |
| `.github/skills/post-pr-review/SKILL.md` | **Step 6 (NEWLY DISCOVERED — was missing from prior plan)**: lines 35 AND 52 `$copilotRoot/.github/skills/session-startup/scripts/post-merge-cleanup.ps1` |
| `.github/skills/skill-creator/SKILL.md` | Step 5 |
| `.github/skills/README.md` | Step 5 |

### Skills — routing assets (2) — Step 5

| File | Notes |
|---|---|
| `.github/skills/routing-tables/assets/routing-config.json` | JSON path literals |
| `.github/skills/routing-tables/assets/gate-criteria.json` | JSON path literals |

### Skill-internal scripts (4) — Step 6

| File | Notes |
|---|---|
| `.github/skills/session-startup/scripts/post-merge-cleanup.ps1` | Runtime `$copilotRoot/.github/skills` |
| `.github/skills/session-startup/scripts/session-cleanup-detector-core.ps1` | Runtime `$copilotRoot/.github/skills` |
| `.github/skills/guidance-measurement/scripts/measure-guidance-complexity.ps1` | Runtime `$copilotRoot/.github/skills` |
| `.github/skills/guidance-measurement/scripts/measure-guidance-complexity-core.ps1` | Runtime `$copilotRoot/.github/skills` |

### Pester tests (21) — Step 9 (batched)

| File | Notes |
|---|---|
| `.github/scripts/Tests/validate-plugin-preflight.Tests.ps1` | Path literals |
| `.github/scripts/Tests/quick-validate.Tests.ps1` | Path literals |
| `.github/scripts/Tests/session-startup-wording-contract.Tests.ps1` | **Regex special-case — line 28**: `\$copilotRoot/\.github/skills/...` pattern → `\$copilotRoot/skills/...` (double-escape for `\.`) |
| `.github/scripts/Tests/write-calibration-entry.Tests.ps1` | Path literals |
| `.github/scripts/Tests/session-cleanup-detector.Tests.ps1` | Path literals |
| `.github/scripts/Tests/script-safety-contract.Tests.ps1` | Path literals |
| `.github/scripts/Tests/prevention-analysis-gate-contract.Tests.ps1` | Path literals |
| `.github/scripts/Tests/measure-guidance-complexity.Tests.ps1` | Path literals |
| `.github/scripts/Tests/handoff-persistence-contract.Tests.ps1` | Path literals |
| `.github/scripts/Tests/guidance-complexity-contract.Tests.ps1` | Path literals |
| `.github/scripts/Tests/downstream-ownership-boundary-contract.Tests.ps1` | Path literals |
| `.github/scripts/Tests/create-improvement-issue.Tests.ps1` | Path literals |
| `.github/scripts/Tests/check-port.Tests.ps1` | Path literals |
| `.github/scripts/Tests/backfill-calibration.Tests.ps1` | Path literals |
| `.github/scripts/Tests/aggregate-review-scores.Tests.ps1` | Path literals |
| `.github/scripts/Tests/continuation-contract.Tests.ps1` | Path literals |
| `.github/scripts/Tests/routing-tables.Tests.ps1` | Path literals |
| `.github/scripts/Tests/bdd-scenario-contract.Tests.ps1` | Path literals |
| `.github/scripts/Tests/ce-gate-multi-path-coverage-contract.Tests.ps1` | Path literals |
| `.github/scripts/Tests/branch-authority-gate-contract.Tests.ps1` | Path literals |
| `.github/scripts/Tests/plan-approval-prompt-contract.Tests.ps1` | Path literals |

### Validators (Step 3 parameterization — 3 files)

| File | Notes |
|---|---|
| `.github/scripts/validate-architecture.ps1` | Step 3(b) — `$RequiredDirectories` array lines 64-67 parameterized |
| `.github/scripts/lib/validate-plugin-preflight-core.ps1` | Step 3(a) — lines 78, 109 (NOT in 82-file scan: scan used `.github/(agents\|skills)` literal; this file derives dirs). Verify in Step 3 |
| `.github/scripts/lib/quick-validate-core.ps1` | Step 3(c) — any hardcoded paths |

Note: preflight-core + quick-validate-core may not appear in the 82-file scan if they use `$RootPath` already; Step 3 inspects and parameterizes as needed.

### Prompts (2) — Step 10(b) or Step 5 depending on content

| File | Notes |
|---|---|
| `.github/prompts/setup.prompt.md` | Step 10(b) + `chat.agentFilesLocations` block (lines 87, 90, 142, 154) — verbatim settings.json update |
| `.github/prompts/start-issue.prompt.md` | Path literal update |

### Top-level docs (4) — Step 10

| File | Notes |
|---|---|
| `README.md` | Step 10(c) — add "Install in Claude Code" + "Install in Copilot" snippets; `chat.agentFilesLocations` line 188 |
| `CUSTOMIZATION.md` | Step 6 migration block (verbatim settings.json keys) + Step 10(d) — `chat.agentFilesLocations` lines 35, 151, 161, 273–276. Migration-note-fenced region is allow-listed |
| `CONTRIBUTING.md` | Step 10(e) — `chat.agentFilesLocations` lines 58, 76 |
| `.github/copilot-instructions.md` | Step 10(b) — lines 17, 34, 40, 72, 81 |

### Architecture + skills-framework (2) — Step 11 / Step 10(e)

| File | Notes |
|---|---|
| `.github/architecture-rules.md` | Step 11 — Directory Structure + Layer Model tables + `platforms/{tool}.md` convention subsection |
| `Documents/Design/skills-framework.md` | Step 10(e) — structural references update (NOT allow-listed despite `Documents/Design/` path — this is a living framework doc, not a historical record) |

### Examples (6) — Step 10(a)

| File | Notes |
|---|---|
| `examples/nodejs-typescript/README.md` | Update |
| `examples/nodejs-typescript/copilot-instructions.md` | Update + `<!-- legacy-path -->` fencing for intentional old-path blocks |
| `examples/python/README.md` | Update |
| `examples/python/copilot-instructions.md` | Update + legacy-path fencing |
| `examples/spring-boot-microservice/README.md` | Update |
| `examples/spring-boot-microservice/copilot-instructions.md` | Update + legacy-path fencing |

---

## ALLOW-LIST — 19 files

`Documents/Design/` historical design records. Sweep gate tolerates `.github/(agents|skills)` occurrences in these files indefinitely.

| File |
|---|
| `Documents/Design/agent-plugin.md` (includes `chat.agentFilesLocations` refs lines 102-104) |
| `Documents/Design/bdd-framework.md` |
| `Documents/Design/browser-tools.md` |
| `Documents/Design/code-review.md` |
| `Documents/Design/customer-experience-gate.md` |
| `Documents/Design/experience-owner.md` |
| `Documents/Design/guidance-complexity.md` |
| `Documents/Design/hub-mode-ux.md` |
| `Documents/Design/migration-safety.md` |
| `Documents/Design/plan-storage.md` |
| `Documents/Design/pre-commit-formatting.md` |
| `Documents/Design/provenance-gate.md` |
| `Documents/Design/safe-operations.md` |
| `Documents/Design/script-library.md` |
| `Documents/Design/session-hooks.md` |
| `Documents/Design/setup-wizard.md` |
| `Documents/Design/step-commits.md` |
| `Documents/Design/terminal-test-hygiene.md` |
| `Documents/Design/tool-support.md` (Step 2 amendment: add "Superseded by ADR-0001" banner preserving D1 content) |

---

## SKIP — 0 files

No files in the 82-hit scan are out of scope. All either UPDATE or ALLOW-LIST.

---

## Deltas vs pre-Step-1 plan

1. **post-pr-review/SKILL.md added to Step 6**: lines 35 and 52 contain `$copilotRoot/.github/skills/session-startup/scripts/post-merge-cleanup.ps1`. Missed in earlier discovery report. Plan step 6 watch-list amended.
2. **Code-Conductor line 778 is Step 5, not Step 6**: verified via `$copilotRoot` grep — only line 143 has the prefix. Line 778 (plain `.github/skills/calibration-pipeline/scripts/write-calibration-entry.ps1`) is plain prose/code-block invocation and falls to Step 5. Plan already contains the judge-sustained correction.
3. **Preflight-core and quick-validate-core path-literal status to be verified in Step 3**: not in the 82-file scan because grep uses literal `.github/(agents|skills)`; these files derive paths from `$RootPath`. Step 3 inspects and parameterizes where applicable.

## Counts

- Agents: 14
- Skill SKILL.md / README: 7
- Skill routing JSON: 2
- Skill-internal .ps1: 4
- Pester tests: 21
- Validators: 3 (Step 3)
- Prompts: 2
- Top-level docs: 4
- Architecture + skills-framework: 2
- Examples: 6
- **UPDATE total**: 63 (+ 3 Step-3 validators not guaranteed in 82-scan) ≈ 63
- **ALLOW-LIST total**: 19
- **Grand total in 82-scan**: 63 UPDATE (from scan) + 19 ALLOW-LIST = 82 ✓

## Deletion schedule

This file is deleted in Step 15(a) along with the step-15 validation ladder completion.
