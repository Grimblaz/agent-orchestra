<!-- audit-meta
last-verified: d13d53bd69c27a6eaa21d666278ac8ee2ce9ee81
generated-at: 2026-05-13T18:18:04Z
-->

## Purpose

This document catalogs all hub artifact path references across five scopes of the Agent Orchestra plugin, providing downstream consumer repository maintainers with a reliable inventory of what paths are safe to reference and how each is resolved.

## Customer

Downstream consumer-repo maintainers who install `agent-orchestra@agent-orchestra` via the Claude plugin marketplace or as a Copilot extension and need to understand which hub artifacts their repo can reference without breaking.

## Methodology

This audit document is produced and kept current by the following pipeline:

(a) **Extraction script and grammar spec** (`.github/scripts/audit-hub-artifact-paths.ps1`): scans five locked scopes — agent bodies (`agents/*.agent.md`), Claude shells (`agents/*.md`), skill bodies (`skills/*/SKILL.md`), command files (`commands/*.md`), and manifests-and-hooks — extracting backtick-fenced inline path references (Markdown grammar), JSON string values (JSON grammar), and single/double-quoted string literals (PowerShell grammar) that end with an allowed extension (`md`, `ps1`, `yml`, `yaml`, `json`, `sh`).

(b) **Classification YAML** (`Documents/Design/hub-artifact-paths-classification.yml`): maps each normalized path family to its resolution behavior for Claude and Copilot, the consumer experience when a path is absent, and whether modifying files in that family requires a plugin version bump.

(c) **D2a placeholder normalization**: before family clustering, all eight template placeholder tokens are normalized to `*`:
- `{ID}`
- `{PR}`
- `{NUMBER}`
- `{name}`
- `{port}`
- `{ISSUE_NUMBER}`
- `{N}`
- `{Surface}`

(d) **Pester drift gate** (Step 5 test: `.github/scripts/Tests/hub-artifact-paths-coverage.Tests.ps1`): asserts that `-Diff` reports `added: 0; removed: 0; uncategorized: 0`, blocking merges when the inventory diverges from the classification.

(e) **Pester CI workflow** (Step 4: `.github/workflows/pester.yml`): runs the full Pester suite on every pull request, including the extraction grammar tests and drift gate.

(f) **Reproduction recipes for CE Gate**:

**Hub-repo verification** (maintainers): from the cloned agent-orchestra working tree, run `pwsh .github/scripts/audit-hub-artifact-paths.ps1 -Diff`. A result of `added: 0; removed: 0; uncategorized: 0` confirms the classification covers all inventory paths in the current working tree.

**Consumer scratch-repo verification** (downstream consumers): in a fresh directory that contains only a consumer project (no agent-orchestra source tree), install the plugin via `claude plugin install agent-orchestra@agent-orchestra`. Then obtain the script from the plugin cache (path shown by `cat ~/.claude/plugins/installed_plugins.json` → `installPath`) and run it from your consumer repo root: `pwsh <installPath>/.github/scripts/audit-hub-artifact-paths.ps1 -Diff`. A zero-result output confirms the installed plugin cache matches the current classification.

(g) **Verification Log** (CE Gate s9, issue [#243](https://github.com/Grimblaz/agent-orchestra/issues/243), 2026-05-13): 12-path spot-check executed against plugin cache v2.13.0. All 12 checks PASS.

| Check | Family | claude_resolves / copilot_resolves | Mechanism | Result |
|---|---|---|---|---|
| C1 | `agents/*.agent.md` | both | plugin-cache hit: `agents/Code-Critic.agent.md`; source-tree hit | PASS |
| C2 | `agents/*.md` | plugin-cache | plugin-cache hit: `agents/code-critic.md`; registered in `agents[]` array | PASS |
| C3 | `skills/*/SKILL.md` | both | plugin-cache hit: `skills/session-startup/SKILL.md`; source-tree hit | PASS |
| C4 | `commands/*.md` | plugin-cache | plugin-cache hit: `commands/orchestrate.md` | PASS |
| C5 | `.claude-plugin/*.json` | plugin-cache | `.claude-plugin/plugin.json` present in plugin cache | PASS |
| C6 | `.github/scripts/*.ps1` | plugin-cache | plugin-cache hit: `.github/scripts/frame-credit-ledger.ps1` | PASS |
| P1 | `agents/*.agent.md` | source-tree | `agents/Code-Conductor.agent.md` present in hub source tree | PASS |
| P2 | `skills/*/SKILL.md` | source-tree | `skills/customer-experience/SKILL.md` + `skills/implementation-discipline/SKILL.md` present | PASS |
| P3 | `skills/*/platforms/*.md` | source-tree | `skills/session-startup/platforms/claude.md` + `copilot.md` present | PASS |
| P4 | `.github/scripts/*.ps1` | source-tree | `.github/scripts/frame-credit-ledger.ps1` present in source tree | PASS |
| P5 | `.github/scripts/lib/*.ps1` | source-tree | `.github/scripts/lib/frame-credit-ledger-core.ps1` present | PASS |
| P6 | `agents/*.md` | not-applicable | Shell registered via `agents[]` in `.claude-plugin/plugin.json` only; no Copilot equivalent | PASS |

Scenario results:

- **S1** (hub agent runs in consumer repo without missing-artifact failures): PASS — all `hard-failure` families present in plugin cache v2.13.0.
- **S2** (audit catalog covers every referenced artifact across five scopes): PASS — `-Diff` reports `added: 0; removed: 0; uncategorized: 0`.
- **S3** (intentionally unresolved references feel informative not broken): PASS — `none`-classified families use `wasted-tool-call` experience with explicit documentation.
- **S4** (maintainer can find the audit and act on it without prior context): PASS — audit doc linked from README.md + CLAUDE.md; Purpose + Customer sections orient a cold reader; `-Diff` output is actionable.

CE Gate result: ✅ CE Gate passed — intent match: strong. Browser, canvas, and api surfaces: ⏭️ not applicable.

## Resolution Taxonomy

### claude_resolves values

- **plugin-cache**: Claude loads the artifact from the installed plugin cache (resolved via `~/.claude/plugins/installed_plugins.json` → `installPath` → artifact path). This is the primary path for consumer runs.
- **source-tree**: Claude reads directly from the working tree (source-repo CWD). Used for hub-only artifacts that are not distributed via the plugin cache.
- **both**: Claude can resolve from either the plugin cache (D1-chain: `installed_plugins.json` → `installPath`) OR from source-repo CWD as fallback. Used for shared artifacts that exist in both contexts.
- **none**: Claude cannot resolve this artifact (it is consumer-generated or session-scoped and not present in any resolvable location).
- **not-applicable**: This family is not applicable from Claude's perspective (e.g., a Copilot-only surface).

### copilot_resolves values

- **plugin-manifest**: Copilot loads the artifact via the plugin manifest registration.
- **source-tree**: Copilot reads directly from the source tree in the hub repo.
- **both**: Copilot can resolve from either the plugin manifest or source tree.
- **none**: Copilot cannot resolve this artifact.
- **not-applicable**: This family is not applicable from Copilot's perspective (e.g., Claude-only shells).

### not-applicable annotation

When a family is `not-applicable` for one tool, the `notes` field in the classification YAML explains the asymmetry — for example, Claude subagent shells (`agents/*.md`) are Claude-only surfaces registered via the `agents[]` array in `.claude-plugin/plugin.json`; Copilot uses `.agent.md` bodies directly and has no corresponding concept.

### Worked dual-resolved example: `agents/Code-Critic.agent.md`

In a **consumer-repo run** (a downstream repo that has installed the plugin), Claude resolves `agents/Code-Critic.agent.md` via the D1-chain:

1. Read `~/.claude/plugins/installed_plugins.json` to find `installPath` for `agent-orchestra@agent-orchestra`.
2. Join `installPath` + `agents/Code-Critic.agent.md` to get the plugin-cache absolute path.
3. Read the file from plugin cache.

In a **hub-repo run** (the agent-orchestra repository itself, with `.claude-plugin/plugin.json` present and no separate plugin install pointing at itself), Claude falls back to source-tree CWD and reads `agents/Code-Critic.agent.md` directly from the working tree.

Copilot always reads from the source tree in the hub repo. This dual-resolved behavior is why the classification records `claude_resolves: both` and `copilot_resolves: source-tree` for the `agents/*.agent.md` family.

## Catalog

### `.claude-plugin/*.json`

- **claude_resolves**: plugin-cache
- **copilot_resolves**: not-applicable
- **requires_version_bump**: false
- **experience**: hard-failure
- **examples**:
  - `.claude-plugin/plugin.json`
  - `.claude-plugin/marketplace.json`
- **notes**: Claude plugin manifest files. plugin.json is the version-triggering artifact itself — modifying it does not require a separate bump because the bump IS the edit to plugin.json. marketplace.json is the marketplace descriptor. Not applicable from Copilot's perspective. Missing or malformed plugin.json = Claude cannot load the plugin at all.

### `.claude/.state/*.json`

- **claude_resolves**: none
- **copilot_resolves**: not-applicable
- **requires_version_bump**: false
- **experience**: wasted-tool-call
- **examples**:
  - `.claude/.state/release-hygiene-{slug}.json`
- **notes**: Claude runtime state files written by the plugin-release-hygiene hook. Session-scoped; not distribution artifacts. Placeholders like {slug} are session-scoped runtime tokens; only the D2a eight ({ID}, {PR}, {NUMBER}, {name}, {port}, {ISSUE_NUMBER}, {N}, {Surface}) are normalized for path-family clustering. Attempting to resolve from plugin cache is a wasted tool call.

### `.claude/settings.json`

- **claude_resolves**: none
- **copilot_resolves**: not-applicable
- **requires_version_bump**: false
- **experience**: wasted-tool-call
- **examples**:
  - `.claude/settings.json`
- **notes**: Consumer-generated Claude Code project settings. Not a distribution artifact; each consumer repo creates its own. Reading from plugin cache or another repo's tree is a wasted tool call.

### `.claude/settings.local.json`

- **claude_resolves**: none
- **copilot_resolves**: not-applicable
- **requires_version_bump**: false
- **experience**: wasted-tool-call
- **examples**:
  - `.claude/settings.local.json`
- **notes**: Consumer-generated local overrides for Claude Code settings. gitignored; not committed to hub or consumer repos. Attempting to resolve is always a wasted tool call.

### `.copilot-tracking/*.json`

- **claude_resolves**: none
- **copilot_resolves**: none
- **requires_version_bump**: false
- **experience**: wasted-tool-call
- **examples**:
  - `.copilot-tracking/calibration/review-data.json`
- **notes**: Consumer-repo Copilot tracking data files (e.g., calibration review data). Not distribution artifacts. Attempting to resolve outside the consumer repo is a wasted tool call.

### `.copilot-tracking/*.md`

- **claude_resolves**: none
- **copilot_resolves**: none
- **requires_version_bump**: false
- **experience**: wasted-tool-call
- **examples**:
  - `.copilot-tracking/research/{YYYYMMDD-name}-research.md`
  - `.copilot-tracking/reviews/{date}-process-review.md`
- **notes**: Consumer-repo research and process-review markdown files produced during Copilot sessions. Not distribution artifacts.

### `.copilot-tracking/*.yml`

- **claude_resolves**: none
- **copilot_resolves**: none
- **requires_version_bump**: false
- **experience**: wasted-tool-call
- **examples**:
  - `.copilot-tracking/issue-42-my-feature.yml`
- **notes**: Consumer-repo Copilot tracking files for in-progress issues. Not distribution artifacts. Consumer-specific; attempting to resolve from the hub repo or plugin cache is a wasted tool call.

### `.github/architecture-rules.md`

- **claude_resolves**: source-tree
- **copilot_resolves**: source-tree
- **requires_version_bump**: false
- **experience**: visible-warning
- **examples**:
  - `.github/architecture-rules.md`
- **notes**: Hub-repo architecture rules. Consumer repos maintain their own copy; the hub copy is a template. Intentionally hub-only per the plan (carved out). Missing produces visible-warning because Copilot instructions reference it but can fall back.

### `.github/copilot-instructions.md`

- **claude_resolves**: source-tree
- **copilot_resolves**: source-tree
- **requires_version_bump**: false
- **experience**: visible-warning
- **examples**:
  - `.github/copilot-instructions.md`
- **notes**: Copilot system prompt injected by GitHub. Intentionally hub-only; consumer repos maintain their own. Missing = Copilot operates without hub-level instruction context (visible-warning, not hard-failure).

### `.github/instructions/*.instructions.md`

- **claude_resolves**: none
- **copilot_resolves**: none
- **requires_version_bump**: false
- **experience**: wasted-tool-call
- **examples**:
  - `.github/instructions/browser-mcp.instructions.md`
  - `.github/instructions/browser-tools.instructions.md`
  - `.github/instructions/local-gotchas.instructions.md`
- **notes**: Consumer-generated VS Code / Copilot instruction files. Not distribution artifacts; created per consumer repo setup. Attempting to resolve these from the plugin cache or a different consumer repo results in a wasted tool call.

### `.github/plugin/marketplace.json`

- **claude_resolves**: plugin-cache
- **copilot_resolves**: source-tree
- **requires_version_bump**: true
- **experience**: hard-failure
- **examples**:
  - `.github/plugin/marketplace.json`
- **notes**: Marketplace descriptor residing under .github/plugin/. Distinct from .claude-plugin/marketplace.json; this copy is consumed by the GitHub-hosted plugin marketplace integration. Missing = marketplace cannot resolve the plugin.

### `.github/scripts/*.ps1`

- **claude_resolves**: plugin-cache
- **copilot_resolves**: source-tree
- **requires_version_bump**: true
- **experience**: visible-warning
- **examples**:
  - `.github/scripts/bump-version.ps1`
  - `.github/scripts/frame-credit-ledger.ps1`
  - `.github/scripts/normalize-whitespace.ps1`
- **notes**: Root-level hook and utility scripts under .github/scripts/. Claude loads from plugin-cache; Copilot runs from source-tree. Missing script produces visible-warning because the hook that calls it will report an error but does not block the pipeline.

### `.github/scripts/lib/*.ps1`

- **claude_resolves**: plugin-cache
- **copilot_resolves**: source-tree
- **requires_version_bump**: true
- **experience**: visible-warning
- **examples**:
  - `.github/scripts/lib/cost-walker-copilot.ps1`
  - `.github/scripts/lib/frame-credit-ledger-core.ps1`
- **notes**: Shared library scripts loaded by root hook scripts under .github/scripts/lib/. Sourced as dependencies at runtime; missing lib script propagates as a visible-warning from the calling hook.

### `.github/scripts/Tests/*.Tests.ps1`

- **claude_resolves**: plugin-cache
- **copilot_resolves**: source-tree
- **requires_version_bump**: true
- **experience**: visible-warning
- **examples**:
  - `.github/scripts/Tests/bdd-scenario-contract.Tests.ps1`
  - `.github/scripts/Tests/subagent-env-handshake.Tests.ps1`
- **notes**: Pester test files. Absent tests produce visible-warning in CI (tests are skipped or the suite reports fewer cases) but do not block agent dispatch.

### `.github/scripts/Tests/fixtures/*.ps1`

- **claude_resolves**: plugin-cache
- **copilot_resolves**: source-tree
- **requires_version_bump**: true
- **experience**: visible-warning
- **examples**:
  - `.github/scripts/Tests/fixtures/subagent-env-handshake-verifier.ps1`
- **notes**: Test fixture scripts. Missing fixture causes the referencing Pester test to fail with a visible error rather than hard-blocking a pipeline run.

### `.vscode/settings.json`

- **claude_resolves**: none
- **copilot_resolves**: none
- **requires_version_bump**: false
- **experience**: wasted-tool-call
- **examples**:
  - `.vscode/settings.json`
- **notes**: Consumer-generated VS Code workspace settings. Not a distribution artifact. gitignored or consumer-specific; never resolved from the hub repo or plugin cache.

### `/memories/session/*.md`

- **claude_resolves**: none
- **copilot_resolves**: none
- **requires_version_bump**: false
- **experience**: wasted-tool-call
- **examples**:
  - `/memories/session/plan-issue-{ID}.md`
  - `/memories/session/design-issue-{ID}.md`
  - `/memories/session/review-state-{ID}.md`
- **notes**: Claude Code session-only memory files written during a live session. Not distribution artifacts and not committed to any repo. Placeholders {ID} and {N} are in the D2a set; {id} (lowercase), {scope}, {primary}, {secondary1}, {secondaryN} are session-scoped runtime tokens, not D2a-normalized. Only the canonical eight ({ID}, {PR}, {NUMBER}, {name}, {port}, {ISSUE_NUMBER}, {N}, {Surface}) are normalized for path-family clustering. Any agent that tries to Read a path in this family when no session is active performs a wasted tool call.

### `agents/*.agent.md`

- **claude_resolves**: both
- **copilot_resolves**: source-tree
- **requires_version_bump**: true
- **experience**: hard-failure
- **examples**:
  - `agents/Code-Smith.agent.md`
  - `agents/Code-Conductor.agent.md`
  - `agents/Code-Critic.agent.md`
- **notes**: Shared agent bodies; loaded by paired Claude shells via D1 plugin-cache-first chain (installed_plugins.json -> plugin-cache path) with source-repo CWD as fallback. Copilot reads directly from source tree in the hub repo. Missing body = agent dispatch fails at first Read call.

### `agents/*.md`

- **claude_resolves**: plugin-cache
- **copilot_resolves**: not-applicable
- **requires_version_bump**: true
- **experience**: hard-failure
- **examples**:
  - `agents/code-smith.md`
  - `agents/code-critic.md`
  - `agents/spine-runner.md`
- **notes**: Claude-only subagent shells; paired to shared agent bodies; registered via the explicit agents[] array in .claude-plugin/plugin.json. Not applicable for Copilot tool perspective — Copilot uses .agent.md bodies directly. Missing shell = subagent_type dispatch fails in Claude.

### `commands/*.md`

- **claude_resolves**: plugin-cache
- **copilot_resolves**: not-applicable
- **requires_version_bump**: true
- **experience**: hard-failure
- **examples**:
  - `commands/orchestrate.md`
  - `commands/spine-run.md`
  - `commands/orchestra-review.md`
- **notes**: Claude Code slash command entry points registered via the commands[] array in .claude-plugin/plugin.json. Copilot slash commands are a distinct surface — these .md command files are not applicable from Copilot's perspective.

### `Documents/Design/*.md`

- **claude_resolves**: source-tree
- **copilot_resolves**: source-tree
- **requires_version_bump**: false
- **experience**: visible-warning
- **examples**:
  - `Documents/Design/frame-architecture.md`
  - `Documents/Design/session-memory-contract.md`
  - `Documents/Design/hub-artifact-paths-audit.md`
- **notes**: Hub-repo design documents (.md files). Intentionally hub-only per the plan (carved out). Agents and skills cross-reference these for design intent, but consumers do not receive them. Paths with {domain-slug} and {domain} placeholders are D2a-normalized. Missing = agent proceeds without design context (visible-warning, not hard-failure).

### `Documents/Design/*.yml`

- **claude_resolves**: source-tree
- **copilot_resolves**: source-tree
- **requires_version_bump**: false
- **experience**: visible-warning
- **examples**:
  - `Documents/Design/hub-artifact-paths-classification.yml`
- **notes**: Hub-repo design YAML data files (e.g., classification schemas). Intentionally hub-only per the plan (carved out). Same resolution and experience semantics as Documents/Design/*.md — agents that cross-reference these for schema or classification data will proceed without that context if the file is absent (visible-warning).

### `examples/{stack}/*.md`

- **claude_resolves**: source-tree
- **copilot_resolves**: source-tree
- **requires_version_bump**: false
- **experience**: wasted-tool-call
- **examples**:
  - `examples/{stack}/architecture-rules.md`
  - `examples/{stack}/copilot-instructions.md`
- **notes**: Example consumer-repo templates. Placeholder {stack} is D2a-normalized. These are reference templates for new consumer repo setup, not loaded at runtime. Attempting to resolve a specific example path during agent execution is a wasted tool call.

### `frame/pipeline-metrics-v4-schema.md`

- **claude_resolves**: both
- **copilot_resolves**: source-tree
- **requires_version_bump**: true
- **experience**: hard-failure
- **examples**:
  - `frame/pipeline-metrics-v4-schema.md`
- **notes**: Frame pipeline metrics schema document. Authoritative schema for the <!-- pipeline-metrics --> block format. Missing = credit-emission agents cannot validate block structure.

### `frame/ports/*.yaml`

- **claude_resolves**: both
- **copilot_resolves**: source-tree
- **requires_version_bump**: true
- **experience**: hard-failure
- **examples**:
  - `frame/ports/process-retrospective.yaml`
  - `frame/ports/{port}.yaml`
- **notes**: Frame port declaration files. Consumed by Code-Conductor to validate adapter presence for each step. Placeholder {port} is D2a-normalized. Missing = Conductor cannot verify port fill status, producing hard-failure in frame-spine validation.

### `hooks/hooks.json`

- **claude_resolves**: both
- **copilot_resolves**: source-tree
- **requires_version_bump**: true
- **experience**: hard-failure
- **examples**:
  - `hooks/hooks.json`
- **notes**: Bare-relative reference from within a skill body pointing to the root hooks/hooks.json Copilot hooks configuration. Copilot reads from source-tree; Claude loads from plugin-cache. Missing = hook registration fails for Copilot.

### `skills/*/adapters/*.md`

- **claude_resolves**: both
- **copilot_resolves**: source-tree
- **requires_version_bump**: true
- **experience**: hard-failure
- **examples**:
  - `skills/process-retrospective/adapters/explicit-skip-process-retrospective.md`
  - `skills/process-retrospective/adapters/auto-na-process-retrospective.md`
  - `skills/{skill}/adapters/{adapter}.md`
- **notes**: Frame adapter documents nested within skill directories. Bare-relative paths 'adapters/{port}.md', 'adapters/auto-na-{port}.md', 'adapters/auto-na-experience.md', 'adapters/explicit-skip-{port}.md', and 'adapters/explicit-skip-experience.md' are relative references from skill body text that map to this family.

### `skills/*/assets/*.json`

- **claude_resolves**: both
- **copilot_resolves**: source-tree
- **requires_version_bump**: true
- **experience**: hard-failure
- **examples**:
  - `skills/routing-tables/assets/gate-criteria.json`
  - `skills/routing-tables/assets/routing-config.json`
- **notes**: JSON data assets nested within skill directories. Bare-relative paths 'assets/gate-criteria.json' and 'assets/routing-config.json' appearing in skill body text are relative references that map to this family. Routing logic that reads these files will hard-fail if they are missing.

### `skills/*/platforms/*.md`

- **claude_resolves**: both
- **copilot_resolves**: source-tree
- **requires_version_bump**: true
- **experience**: hard-failure
- **examples**:
  - `skills/session-startup/platforms/claude.md`
  - `skills/upstream-onboarding/platforms/claude.md`
  - `skills/parallel-execution/platforms/copilot.md`
- **notes**: Platform-specific invocation details for each skill. Bare-relative references 'platforms/claude.md' and 'platforms/copilot.md' appearing in skill body text are relative to the containing skill directory and map to this family. Missing = agent uses wrong platform bindings or silently omits platform-specific steps.

### `skills/*/references/*.md`

- **claude_resolves**: both
- **copilot_resolves**: source-tree
- **requires_version_bump**: true
- **experience**: hard-failure
- **examples**:
  - `skills/calibration-pipeline/references/findings-construction.md`
  - `skills/validation-methodology/references/post-judgment-routing.md`
  - `skills/parallel-execution/references/error-handling.md`
- **notes**: Reference sub-documents within skill directories. Bare-relative paths such as 'references/anti-patterns.md', 'references/commands.md', 'references/quality-gates.md', and 'references/test-patterns.md' appearing in skill body text are relative references that map to this family. Missing reference docs produce hard-failure when a skill body tries to Read them during execution.

### `skills/*/scripts/*.ps1`

- **claude_resolves**: both
- **copilot_resolves**: source-tree
- **requires_version_bump**: true
- **experience**: visible-warning
- **examples**:
  - `skills/session-startup/scripts/post-merge-cleanup.ps1`
  - `skills/session-startup/scripts/session-cleanup-detector.ps1`
  - `skills/plugin-release-hygiene/scripts/plugin-release-hygiene-hook.ps1`
- **notes**: PowerShell helper scripts nested within skill directories. Bare-relative paths 'scripts/session-cleanup-detector.ps1' appearing in skill text, and 'lib/*.ps1' paths (e.g., 'lib/cost-anomaly.ps1', 'lib/frame-spine-core.ps1') referenced from within skills/copilot-cost-collection/ context, map to this family or skills/lib/*.ps1. Missing script produces visible-warning rather than hard-failure because the skill body can fall back to inline guidance.

### `skills/*/SKILL.md`

- **claude_resolves**: both
- **copilot_resolves**: source-tree
- **requires_version_bump**: true
- **experience**: hard-failure
- **examples**:
  - `skills/implementation-discipline/SKILL.md`
  - `skills/parallel-execution/SKILL.md`
  - `skills/session-startup/SKILL.md`
- **notes**: Core skill bodies. Paths like 'bdd-scenarios/SKILL.md', 'customer-experience/SKILL.md', 'plugin-release-hygiene/SKILL.md', 'post-pr-review/SKILL.md', and 'session-startup/SKILL.md' appearing without the skills/ prefix are relative references from within skill subdirectories and map to this same family. Both Claude (plugin-cache D1 or source-tree fallback) and Copilot (source-tree) must resolve these for agent methodology to function.

### `templates/*.md`

- **claude_resolves**: both
- **copilot_resolves**: source-tree
- **requires_version_bump**: true
- **experience**: visible-warning
- **examples**:
  - `templates/describe-block.md`
  - `templates/test-file.md`
- **notes**: Bare-relative template references from within skill bodies (e.g., referenced as 'templates/describe-block.md' from a skill directory). Provide scaffolding patterns for BDD/test authoring. Missing = agent proceeds without template guidance (visible-warning, not hard-failure, since inline examples can substitute).

### `workflows/*.md`

- **claude_resolves**: both
- **copilot_resolves**: source-tree
- **requires_version_bump**: true
- **experience**: visible-warning
- **examples**:
  - `workflows/make-tests-pass.md`
  - `workflows/refactor-safely.md`
  - `workflows/validate-coverage.md`
- **notes**: Bare-relative workflow recipe references from within skill bodies. These provide step-by-step execution guides. Missing = agent falls back to inline methodology in the skill body (visible-warning, not hard-failure).

## Unresolved-Path Experience

The `experience` field in the classification describes what a downstream consumer observes when a path in that family cannot be resolved.

### hard-failure

The agent dispatch or skill load fails immediately. The consumer sees an explicit error message and no fallback is available.

**Example families**: `agents/*.agent.md`, `agents/*.md`, `commands/*.md`, `skills/*/SKILL.md`, `skills/*/platforms/*.md`, `skills/*/references/*.md`, `skills/*/adapters/*.md`, `skills/*/assets/*.json`, `.claude-plugin/*.json`, `.github/plugin/marketplace.json`, `frame/ports/*.yaml`, `frame/pipeline-metrics-v4-schema.md`, `hooks/hooks.json`

### visible-warning

The pipeline continues but the consumer sees an error or warning message. A fallback path exists (e.g., the agent falls back to inline guidance in the skill body).

**Example families**: `skills/*/scripts/*.ps1`, `.github/scripts/*.ps1`, `.github/scripts/lib/*.ps1`, `.github/scripts/Tests/*.Tests.ps1`, `.github/scripts/Tests/fixtures/*.ps1`, `.github/architecture-rules.md`, `.github/copilot-instructions.md`, `Documents/Design/*.md`, `templates/*.md`, `workflows/*.md`

### wasted-tool-call

The agent issues a file-read tool call that returns nothing (or an empty result) because the artifact does not exist in the expected location. No error surface; the agent silently proceeds without the content.

**Example families**: `/memories/session/*.md`, `.github/instructions/*.instructions.md`, `.claude/settings.json`, `.claude/settings.local.json`, `.claude/.state/*.json`, `.copilot-tracking/*.yml`, `.copilot-tracking/*.json`, `.copilot-tracking/*.md`, `.vscode/settings.json`, `examples/{stack}/*.md`

### silent-skip

The path reference is recognized as consumer-local or gitignored; the agent skips loading it without issuing a tool call or warning.

**Example families**: None currently classified. This experience tier is reserved for families where the agent has explicit consumer-local knowledge and suppresses the tool call entirely.

## Historical Context

This section documents specific path migration findings (MF) that influenced the audit scope.

### MF1 — Workspace-relative `.github/skills/{name}/SKILL.md` pattern (2026-05-12 drift-confirmation)

The literal `.github/skills/{name}/SKILL.md` workspace-relative pattern is absent from all five audited scopes. This was a pre-plugin-migration path pattern used before the Agent Orchestra plugin migration. After the migration, agent bodies and skill references moved to the `skills/*/SKILL.md` family (plugin-cache-distributed). The extraction script finds zero matches for this pattern in the current inventory. **Inventory citations**: zero — this path family no longer appears in any audited scope file.

### MF7 — Agent body path family resolution under the plugin cache

The `agents/*.agent.md` family documents how shared agent bodies (e.g., `agents/Code-Conductor.agent.md`, `agents/Code-Critic.agent.md`) are resolved after the plugin migration. Rather than the old workspace-relative path, Claude now resolves these via the D1-chain: `installed_plugins.json` → `installPath` → agent body path in the plugin cache. Source-repo CWD is the fallback for hub-repo runs. **Inventory citations**: the `agents/*.agent.md` family entry in the Catalog section above, with examples including `agents/Code-Conductor.agent.md`, `agents/Code-Critic.agent.md`, and `agents/Code-Smith.agent.md`.

### MF18 — `skills/skill-creator/SKILL.md` reference resolution

`skills/skill-creator/SKILL.md` is referenced within the audited scopes and falls under the `skills/*/SKILL.md` family. In Claude consumer runs this resolves from the plugin cache (D1-chain: `installed_plugins.json` → `installPath` → `skills/skill-creator/SKILL.md`). In hub-repo runs it resolves from the source-tree CWD. **Inventory citations**: `skills/skill-creator/SKILL.md` appears in the current extraction inventory, confirming the reference is live and the classification entry for `skills/*/SKILL.md` covers it.

## How to Detect Staleness

The audit document can become stale when agent bodies, skill files, or command files add or remove path references without a corresponding update to the classification YAML.

(a) **Run the diff tool**: execute `pwsh .github/scripts/audit-hub-artifact-paths.ps1 -Diff` from the repo root. This produces a single-line report:

```
added: N; removed: N; uncategorized: N
```

A result of `added: 0; removed: 0; uncategorized: 0` means the classification covers all inventory paths. Any non-zero value identifies the gap.

(b) **Pester drift gate**: the Pester test `.github/scripts/Tests/hub-artifact-paths-coverage.Tests.ps1` runs `-Diff` and asserts that all three counts are zero. It runs as part of the CI workflow at `.github/workflows/pester.yml` on every pull request.

(c) **`<!-- audit-meta -->` header**: the `last-verified` SHA in the audit-meta comment block at the top of this file records the HEAD commit at the time this document was last regenerated. Compare it against `git rev-parse HEAD` to see whether a regeneration pass has occurred since the last code change.

## Out of Scope

### Internal design documents

`Documents/Design/*.md` files are carved out of the downstream-consumer scope because they are internal design and decision records for the Agent Orchestra hub repository. Downstream consumer repositories do not receive these files through the plugin distribution mechanism (they are not included in the plugin cache). Agents and skills may cross-reference them for design intent during hub-repo development, but a consumer repo that attempts to resolve a `Documents/Design/*.md` path receives a visible-warning (the agent proceeds without the design context) rather than a hard-failure.

**(AC9 follow-up tracking issue: [#561](https://github.com/Grimblaz/agent-orchestra/issues/561))**

### Intentionally hub-only families

The following families are present in the classification but are explicitly excluded from downstream-consumer resolution contracts, because the artifacts they contain are generated at runtime or are consumer-specific:

- **`/memories/session/*.md`**: Claude Code session-only memory files written during a live session. Not committed to any repository. Any agent that reads a path in this family when no session is active performs a wasted tool call.
- **`.copilot-tracking/`** (covering `.copilot-tracking/*.yml`, `.copilot-tracking/*.json`, `.copilot-tracking/*.md`): Consumer-repo Copilot tracking files for in-progress issues, calibration data, and process-review outputs. These are per-consumer-repo artifacts and are not distributed by the hub.
- **`.claude/.state/*.json`**: Claude runtime state files written by the plugin-release-hygiene hook. Session-scoped; not distribution artifacts.
- **`.github/instructions/*.instructions.md`**: Consumer-generated VS Code / Copilot instruction files created per consumer repo setup. Not distribution artifacts.
- **`.claude/settings.json`** and **`.claude/settings.local.json`**: Consumer-generated Claude Code settings files. Each consumer repo creates its own; they are never resolved from the hub repo or plugin cache.
- **`.vscode/settings.json`**: Consumer-generated VS Code workspace settings. Not a distribution artifact.
- **`examples/{stack}/*.md`**: Reference templates for new consumer repo setup, not loaded at runtime by agents.
