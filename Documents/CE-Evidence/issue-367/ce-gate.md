# CE Gate Evidence — Issue #367 (Shape A cross-tool migration + v2.0.0 rename)

**Date**: 2026-04-19
**Scenarios**: S1–S5 (Customer Framing from issue body)
**Branch**: `feature/issue-367-cross-tool-shape-a`
**Version shipped**: v2.0.0 (breaking: repo rename `copilot-orchestra` → `agent-orchestra`, env var surface removed)

---

## Summary Table

| # | Scenario | Status | Mode |
|---|---|---|---|
| S1 | Copilot consumer install | ✅ Verified | Auto (preflight + manifest inspection) |
| S2 | Claude Code consumer install | ✅ Verified | Auto (Claude CLI `plugin validate` + `--plugin-dir` runtime load) |
| S3 | Contributor experience (shared layout) | ✅ Verified | Auto (filesystem + architecture rules) |
| S4 | Legacy migration | ✅ Verified | Auto (doc inspection) |
| S5 | Cross-tool parity | ✅ Verified | Auto (canonical-footer test + platforms/ coverage) |

---

## S1 — Copilot consumer install

**Claim**: Installing the orchestra as a VS Code plugin registers all agents/skills with zero behavior change.

**Evidence**:

- `plugin.json` (at repo root; relocated from `.github/plugin.json` in v2.0.0 per issue #367 D10) declares `name: agent-orchestra`, `version: 2.0.0`; uses plugin-root-relative `./agents/` and `./skills/{name}/` paths.
- `pwsh .github/scripts/validate-plugin-preflight.ps1` → **7/7 checks PASS**:
  - PluginJsonExists, PlaceholdersReplaced, AgentPathsExist, AgentCount=14, SkillPathsExist, SkillCountMatch=39, NoUnsupportedFields (no `commands` field)
- Agent count on disk: **14** (`agents/*.agent.md`) — matches manifest declaration.
- Skill count: **39** declared in manifest; **40** directories on disk — the extra directory is scaffolding (`skills/calibration-pipeline/assets/` is a sibling of skill dirs, not a skill), and `validate-plugin-preflight` confirms declared skills all exist.
- Full Pester suite including `validate-plugin-preflight.Tests.ps1` (28 tests) → all pass.

**Status**: ✅ PASS

---

## S2 — Claude Code consumer install

**Claim**: `/plugin install Grimblaz/agent-orchestra` (or local-path install) registers all 14 agents and 39 skills in Claude Code natively.

**Evidence authorable in CI**: Manifest-level and structural verification complete.

- `.claude-plugin/plugin.json` exists at repo root. Parsed fields: `name=agent-orchestra` (kebab-case ✅), `version=2.0.0`, `author.name=Grimblaz`, `homepage=https://github.com/Grimblaz/agent-orchestra`, `license=MIT`, 8 keywords.
- ADR-0002 auto-discovery conformance: neither `agents` nor `skills` field present in Claude Code manifest (omitting them is required to keep auto-discovery active — the documented footgun).
- Auto-discovered content on disk matches manifest expectation:
  - 14 agent files at `agents/*.agent.md`, all with valid YAML frontmatter.
  - 39 skill directories at `skills/<name>/`, all containing `SKILL.md`.
- All 6 platform-split skills (`session-startup`, `provenance-gate`, `step-commit`, `parallel-execution`, `design-exploration`, `customer-experience`) have both `platforms/claude.md` and `platforms/copilot.md`.
- Spot-checked skill frontmatter for the S2 subset (`session-startup`, `post-pr-review`, `customer-experience`) — all parse cleanly with `name` + `description`.
- Canonical routing-footer parity verified by `session-startup-wording-contract.Tests.ps1` in the 427-test Pester pass (EOL-normalized byte-scope check).
- Dual-manifest version parity: `plugin.json` v2.0.0 = `.claude-plugin/plugin.json` v2.0.0.

**Runtime evidence** (D13 upgrade — Claude CLI `@anthropic-ai/claude-code@2.1.114` installed during CE Gate; superseded the original manual-only plan):

- `claude plugin validate C:/Users/Micah/Code/Copilot-Orchestra` — ✅ `Validation passed` (after frontmatter + marketplace fixes — see "Bugs found and fixed" below).
- `claude plugin marketplace add C:/Users/Micah/Code/Copilot-Orchestra` — ✅ `Successfully added marketplace: agent-orchestra (declared in user settings)`.
- `claude plugin install agent-orchestra@agent-orchestra` — ✅ `Successfully installed plugin: agent-orchestra@agent-orchestra (scope: user)` with `Version: 2.0.0` and `Status: ✔ enabled`.
- Installed plugin surfaces **39 skills** under the `agent-orchestra:*` namespace (non-interactive `claude --print` list): adversarial-review, bdd-scenarios, brainstorming, browser-canvas-testing, calibration-pipeline, code-review-intake, customer-experience, design-exploration, documentation-finalization, frontend-design, guidance-measurement, implementation-discipline, parallel-execution, plan-authoring, post-pr-review, pre-commit-formatting, process-analysis, process-troubleshooting, property-based-testing, provenance-gate, refactoring-methodology, research-methodology, review-judgment, routing-tables, safe-operations, session-startup, skill-creator, software-architecture, specification-authoring, step-commit, systematic-debugging, terminal-hygiene, test-driven-development, tracking-format, ui-iteration, ui-testing, validation-methodology, verification-before-completion, webapp-testing.
- Pre-install `--plugin-dir` run surfaced **14 agents**: Code-Conductor, Code-Critic, Code-Review-Response, Code-Smith, Doc-Keeper, Experience-Owner, Issue-Planner, Process-Review, Refactor-Specialist, Research-Agent, Solution-Designer, Specification, Test-Writer, UI-Iterator.

**Bugs found and fixed** (real D13 payoff — both would have shipped silently broken without runtime validation):

1. **YAML frontmatter parse failure (all 39 skills)**. First runtime pass under `claude plugin validate` rejected every skill with `frontmatter: YAML frontmatter failed to parse: YAML Parse error: Unexpected token. At runtime this skill loads with empty metadata (all frontmatter fields silently dropped)`.
   - Root cause: Claude Code's YAML parser treats unquoted `description:` values containing embedded `:` (colon-space) as malformed. Our `description:` fields commonly included phrases like `DO NOT USE FOR:` or `Use when X: do Y` — valid-looking prose that tripped the strict YAML reader.
   - Upstream impact if unfixed: 39 skills would have loaded under the plugin but with silently dropped metadata — no `name`, no `description` visible to Claude Code's skill matcher, breaking `/skill` routing.
   - Fix: wrapped the `description:` value in double quotes for all 39 skills + 1 affected agent (`Issue-Planner.agent.md`). 13 other agents were already compliant.

2. **Missing `.claude-plugin/marketplace.json`**. The README documented the marketplace install flow (`/plugin marketplace add Grimblaz/agent-orchestra` + `/plugin install agent-orchestra@...`), but consumers running that flow would have failed with `Marketplace file not found at .claude-plugin/marketplace.json`. The Copilot-side `.github/plugin/marketplace.json` existed but uses an incompatible schema (`plugins.0.source: Invalid input` under Claude's parser).
   - Fix: added `.claude-plugin/marketplace.json` using Claude Code's marketplace schema (ref: <https://code.claude.com/docs/en/plugin-marketplaces>). `source: "./"` points the plugin entry at the marketplace root. Name is kebab-case (`agent-orchestra`); owner, version, description, and keywords mirror the plugin manifest.

Post-fix: `claude plugin validate` returns `✔ Validation passed`; local marketplace-add + install succeeds; 39 skills surface under the installed-plugin namespace. These are the most valuable findings in the CE Gate and validate D13's insistence on runtime verification.

**Status**: ✅ VERIFIED (full Claude CLI runtime: validate + marketplace add + plugin install + skill enumeration; two real bugs caught and fixed in this gate).

---

## S3 — Contributor experience (shared layout, tool-neutral intent)

**Claim**: Contributors editing the orchestra see the same file layout regardless of which tool they use; intent is platform-neutral, tool calls are routed per platform.

**Evidence**:

- Repo-root content directories (`agents/`, `skills/`) are the single source of truth for both Copilot and Claude Code manifests — no tool-specific content duplication.
- `.github/architecture-rules.md` Directory Structure + Layer Model tables updated to reflect root-level paths.
- `platforms/` convention documented in architecture rules; intent-only content in `SKILL.md`, platform-specific tool invocations isolated in `platforms/{copilot,claude}.md`.
- `.github/scripts/validate-architecture.ps1` → all validations pass (directory structure, required files).
- Contributor-facing docs (`CONTRIBUTING.md`, `CUSTOMIZATION.md`, `README.md`) reference the new layout consistently.

**Status**: ✅ PASS

---

## S4 — Legacy migration (one-time settings update)

**Claim**: Copilot users upgrading past this PR perform a one-time settings update; no dual-path coexistence.

**Evidence**:

- `README.md` §"Migrating from copilot-orchestra" documents the four migration steps:
  1. Optional cleanup of legacy `COPILOT_ORCHESTRA_ROOT` / `WORKFLOW_TEMPLATE_ROOT` env vars (v2.0.0 makes these inert)
  2. Update VS Code plugin settings (uninstall old, install new)
  3. Update Claude Code plugin (install new)
  4. Update git remote (GitHub auto-redirects; optional explicit rename)
- `CUSTOMIZATION.md` §"Migrating from pre-1.14 layouts" retains the agents/skills-location migration note.
- `CUSTOMIZATION.md` §6 "Session Startup Check" explicitly notes v2.0.0 removed env var dependency.
- No dual-publish: env var resolver deleted from `session-cleanup-detector-core.ps1`; wrapper self-resolves via `$PSScriptRoot`.
- Legacy plugin name `copilot-orchestra` GitHub URLs auto-redirect per GitHub rename semantics; migration doc notes this explicitly.

**Status**: ✅ PASS

---

## S5 — Cross-tool parity (same behavior on both platforms)

**Claim**: Skills and agents behave the same on both platforms; platform-specific tool syntax lives in `platforms/{tool}.md` so SKILL.md reads identically.

**Evidence**:

- All 6 platform-coupled skills have both platform files:

  ```text
  skills/session-startup/platforms/{claude,copilot}.md       ✅
  skills/provenance-gate/platforms/{claude,copilot}.md        ✅
  skills/step-commit/platforms/{claude,copilot}.md            ✅
  skills/parallel-execution/platforms/{claude,copilot}.md     ✅
  skills/design-exploration/platforms/{claude,copilot}.md     ✅
  skills/customer-experience/platforms/{claude,copilot}.md    ✅
  ```

- Canonical routing footer verified by the `session-startup-wording-contract.Tests.ps1` suite (part of the 427-test Pester pass).
- `session-startup` retains documented D3b soft exemption (Copilot-specific trigger path preserved in SKILL.md body; routing footer still byte-identical at the footer scope).
- Architecture validation passes for both manifest variants using the same content tree.

**Status**: ✅ PASS

---

## Validation Ladder Evidence (supporting all scenarios)

| Gate | Command | Result |
|---|---|---|
| Architecture sweep | `pwsh .github/scripts/validate-architecture.ps1` | ✅ All validations passed |
| Plugin preflight | `pwsh .github/scripts/validate-plugin-preflight.ps1` | ✅ 7/7 checks passed |
| Pester suite | `Invoke-Pester -Path .github/scripts/Tests` | ✅ 427 passed, 1 skipped, 0 failed |

---

## Outstanding Items

All 5 scenarios verified. CE Gate complete — advance to commit + PR body finalization.

## CE Gate deliverables to future release artifacts

The frontmatter fix raises a gap worth closing before the next release:

- **`validate-plugin-preflight.ps1` should also call `claude plugin validate`** (when the CLI is available) to catch YAML-parse regressions in CI. Currently preflight only checks Copilot path resolution — it caught none of the Claude Code YAML issues. A follow-up issue should add the Claude CLI gate so a future frontmatter-breaking edit fails at preflight rather than waiting for the next CE Gate pass.
