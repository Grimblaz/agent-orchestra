# Agent Orchestra

[![Version](https://img.shields.io/badge/version-v2.5.0-blue.svg)](../../releases)
[![Ready for Production](https://img.shields.io/badge/status-production%20ready-green.svg)](../../releases)

A multi-agent workflow system that orchestrates AI-assisted software development across specialized agents in GitHub Copilot and Claude Code.

> **Renamed from `copilot-orchestra` in v2.0.0.** See the [migration section](#migrating-from-copilot-orchestra) below for the one-time steps to switch over.

## Install as Plugin (VS Code 1.110+)

> **Experimental**: Agent plugins are available in VS Code 1.110 as an experimental feature. Plugin distribution is the fastest way to get started with no cloning required.

### Quick Setup (Plugin)

1. **Enable plugins** — Add to VS Code user settings (`Ctrl+Shift+P` → "Open User Settings (JSON)"):

   ```json
   {
     "chat.plugins.enabled": true,
     "chat.plugins.marketplaces": ["Grimblaz/agent-orchestra"]
   }
   ```

2. **Install** — In the Extensions view (`Ctrl+Shift+X`), search `@agentPlugins agent-orchestra` and install.
3. **Use** — All 14 agents and the shared skill library are immediately available in VS Code Chat.

**What's included in the repo plugin payload**: 14 agents, the shared skill library, and 10 command files under `commands/` (`/design`, `/experience`, `/plan`, `/orchestrate`, `/polish`, `/orchestra:review`, `/orchestra:review-lite`, `/orchestra:review-prosecute`, `/orchestra:review-defend`, `/orchestra:review-judge`). VS Code currently ignores the plugin `commands` field; Claude Code and CLI consumers use it.

**What requires clone/fork**: Instruction files (`.github/instructions/`) and project templates are not distributed via the plugin — they are auto-discovered by VS Code when you clone or fork the repo. Plugin-distributed hooks are also not active when you only point VS Code at a clone via `chat.agentFilesLocations`; deterministic `SessionStart` cleanup and Claude `PostToolUse` release-hygiene prompts require an actual plugin install.

---

## Install as Plugin (Claude Code)

Claude Code auto-discovers `agents/` and `skills/` at the repo root via `.claude-plugin/plugin.json` (metadata only). Install via the built-in marketplace commands:

```text
/plugin marketplace add Grimblaz/agent-orchestra
/plugin install agent-orchestra@agent-orchestra
```

All 14 agents and the shared skill library are immediately available. The marketplace command registers the source; the install command pulls the plugin into Claude Code's cache. See [`Documents/Decisions/0002-claude-code-plugin-schema.md`](Documents/Decisions/0002-claude-code-plugin-schema.md) for the schema rationale (metadata-only manifest preserves auto-discovery).

The plugin payload includes all 14 shared agent definitions and the shared skill library. The Claude-specific command and specialist surface shipped today is outlined below.

### Phase 1 — Upstream agents live in Claude Code

The three upstream agents are first-class Claude Code citizens:

- `/experience` — invoke Experience-Owner for customer framing or CE Gate evidence capture
- `/design` — invoke Solution-Designer for technical design exploration with the 3-pass non-blocking challenge
- `/plan` — invoke Issue-Planner for implementation planning with the full adversarial review pipeline

Each agent reads its shared, tool-agnostic body from `agents/*.agent.md` and follows the named skills. Claude-native tool bindings (`AskUserQuestion`, `Agent`, `gh` CLI via `Bash`) are mapped from the shared body inside each shell at `agents/{name}.md` (lowercase filename for Claude; capitalized `*.agent.md` for Copilot). Plan persistence uses the GitHub comment marker `<!-- plan-issue-{ID} -->` (there is no session-memory equivalent in Claude Code — the marker is the durable record, compatible with Copilot's latest-comment-wins contract). The row-level survival and fallback rules live in [skills/session-memory-contract/SKILL.md](skills/session-memory-contract/SKILL.md).

See [`CLAUDE.md`](CLAUDE.md) for the Claude Code user guide and [issue #369](https://github.com/Grimblaz/agent-orchestra/issues/369) for the design history.

### Phase 2 — Review pipeline live in Claude Code

The Claude review surface now ships in the `orchestra-review-*` command namespace:

- `/orchestra:review` — canonical entry for the full prosecution → defense → judge pipeline
- `/orchestra:review-lite` — small-change variant with a single compact prosecution pass before defense and judge
- `/orchestra:review-prosecute`, `/orchestra:review-defend`, `/orchestra:review-judge` — power-user and partial-rerun entry points for individual stages

### Phase 3 — Code-Conductor orchestration live in Claude Code

- `/orchestrate` — Claude entry point for the full pipeline from durable issue state through implementation, validation, CE Gate, and PR readiness via Code-Conductor

For paused Claude orchestration work, `/orchestrate` is also the resume entry point. The shared workflow's `/implement` wording is Copilot-specific; Claude Phase 3 does not ship a `/implement` command.

Claude's `code-conductor` shell now ships as a thin shell over the shared `agents/Code-Conductor.agent.md` body plus the extracted composite skills, keeping Copilot and Claude behavior aligned without duplicating the orchestration contract.

The durable handoff set for Claude orchestration is the same GitHub-marker contract used cross-tool: `<!-- experience-owner-complete-{ID} -->`, `<!-- design-phase-complete-{ID} -->`, `<!-- design-issue-{ID} -->`, and `<!-- plan-issue-{ID} -->` as applicable to the current resume tier. See [Documents/Design/session-memory-contract.md](Documents/Design/session-memory-contract.md) for the design rationale behind that no-new-mechanism choice.

#### Specialist agents

Claude Code now includes the implementation specialists for Code-Conductor dispatch:

- `Code-Smith` — implementation-focused code changes against an approved plan
- `Test-Writer` — test authoring and test-surface correction
- `Refactor-Specialist` — structure and maintainability cleanup without changing intended behavior
- `Doc-Keeper` — documentation finalization and stale-doc cleanup
- `Process-Review` — retrospective and execution-quality analysis during the orchestration workflow
- `UI-Iterator` — screenshot-driven UI polish and visual refinement
- `Research-Agent` — evidence-driven technical research and recommendation building
- `Specification` — formal specification drafting and refinement

Claude Phase 5 also ships `/polish` as the direct slash-command entry point for UI-Iterator work.

**What requires clone/fork**: same as the VS Code plugin — `.github/instructions/` and project templates are not distributed through the plugin surface. If you only load agents from a clone, Claude will not pick up the plugin-distributed `SessionStart` or `PostToolUse` hooks; those automation paths require `/plugin install`.

---

## Releases

Claude Code caches plugins by the `version` in `.claude-plugin/plugin.json`. If an entry-point file changes without a version bump, cached installs keep serving the previous snapshot even though the repo content changed.

Agent-assisted maintainer flows now route entry-point edits through the shared `plugin-release-hygiene` skill. Claude uses a committed `PostToolUse` hook, Copilot uses an auto-attached instruction file, and both mechanisms converge on one conversation-scoped version-bump decision.

Claude sessions also run an active-assist startup drift check. When the installed `agent-orchestra@agent-orchestra` version is behind the resolved marketplace version, startup runs `claude plugin update`, reports the old and new versions, and asks whether to restart now or continue under the old code until the next session.

### For maintainers

```text
claude plugin list
claude plugin marketplace list
claude plugin marketplace update
claude plugin marketplace add <source>
claude plugin marketplace remove <name>
claude plugin update <plugin@marketplace>
claude plugin install <plugin@marketplace>
claude plugin uninstall <plugin@marketplace>
```

---

## Quick Start — Two Steps

### Step 1: Clone or fork this template

```bash
git clone https://github.com/YOUR-ORG/YOUR-REPO.git
cd YOUR-REPO
```

Or click **"Use this template"** &rarr; **"Create a new repository"** on GitHub.

> **Note**: Creating from the template is optional. `/setup` works in any repo via shared prompts (`chat.promptFilesLocations`). If your workspace is brand-new and empty, don't worry — Phase 0 will automatically create a `README.md` placeholder for you. (VS Code's workspace context provider crashes on zero-file workspaces; Phase 0 handles this.)

### Step 2: Run the setup wizard

Type `/setup` in GitHub Copilot Chat. It runs in six phases with skip gates:

> **Recommended model**: Claude Opus — the setup wizard benefits from deep reasoning for architecture and tech stack decisions. *(o3 or GPT-4o also work well if Opus is unavailable.)*

- **Phase 0** — Auto-detects prerequisites (VS Code version, pwsh, git, gh CLI)
- **Phase 1** — One-time user setup: adds agents and skills to your VS Code settings, and wires repo-local instruction files only when your clone or generated consumer setup actually uses them. Skip if already configured.
- **Phase 2** — Collects project basics (name, language, framework, database). Skip if `copilot-instructions.md` already exists.
- **Phase 3** — Collects architecture and conventions. Skip if `architecture-rules.md` already exists.
- **Phase 4** — Collects build, run, test, lint, and quick-validate commands. Skip offered if Phases 2, 3, and 5 are all skipped.
- **Phase 5** — Generates project scaffolding (`.gitignore` additions, `.vscode/` defaults, `Documents/` structure). Opt-in.

> **Prefer to do it manually?** Create `.github/copilot-instructions.md` and `.github/architecture-rules.md` yourself. See `examples/` for complete filled-in references. For user-level setup, follow [CUSTOMIZATION.md](CUSTOMIZATION.md).

That's it. You're ready to use agents.

---

## Using the Agents

### I want to

| Goal | Start here |
|------|-----------|
| Frame a feature from the customer's perspective | `@Experience-Owner` |
| Pick up a GitHub issue and design a solution | `@Solution-Designer` |
| Create an implementation plan for an issue | `@Issue-Planner` |
| Implement a planned feature end-to-end | `@Code-Conductor` |
| Run the full pipeline end-to-end for an issue | `/orchestrate` |
| Review code and identify risks | `@Code-Critic` |
| Respond to a code review | `@Code-Review-Response` |
| Polish a UI page or component | `@UI-Iterator` |

### Core Workflow

```text
@Experience-Owner → @Solution-Designer → @Issue-Planner → @Code-Conductor → PR
```

1. **@Experience-Owner** — frames the customer problem, defines user journeys and CE Gate scenarios (optional upstream step)
2. **@Solution-Designer** — picks up the issue, explores the design space, updates the issue body with a design
3. **@Issue-Planner** — creates a step-by-step implementation plan
4. **@Code-Conductor** — reads the plan, delegates to internal specialist agents, creates a merge-ready PR

### Example: Start a feature from scratch

```markdown
@Experience-Owner Please frame issue #42 from the customer's perspective.
```

Then, once the design is in the issue:

```markdown
@Code-Conductor Issue #42 is designed and planned. Please implement it.
```

---

## Agent Reference

### Agents you interact with directly (7)

| Agent | What it does |
|-------|-------------|
| **Experience-Owner** | Customer framing, user journeys, and CE Gate scenario definition |
| **Solution-Designer** | Design exploration and issue management |
| **Issue-Planner** | Multi-step implementation plan creation |
| **Code-Conductor** | End-to-end orchestration of implementation |
| **Code-Critic** | Adversarial code review and risk discovery |
| **Code-Review-Response** | Judges review feedback, scores findings, and emits categorization |
| **UI-Iterator** | Systematic UI polish through screenshot-based iteration |

### Internal agents (called automatically by Code-Conductor)

These agents are hidden from the picker (`user-invocable: false`) and are used automatically during `@Code-Conductor` workflows:

Code-Smith, Test-Writer, Refactor-Specialist, Doc-Keeper, Research-Agent, Process-Review, Specification

> See `agents/` (repo root) for full definitions of all 14 agents.

---

## Skills Framework

Skills are domain-specific knowledge packages in `skills/` (repo root) that agents load on demand:

| Skill | When it's used |
|-------|---------------|
| **test-driven-development** | Writing tests first, red-green-refactor, or quality gates |
| **systematic-debugging** | Debugging failures, flaky tests, or tracking root causes |
| **software-architecture** | Layer boundaries, dependency flow, or ADR-level decisions |
| **brainstorming** | Exploring features, evaluating approaches, or complex decisions |
| **frontend-design** | Designing new UI components or evaluating for distinctiveness |
| **ui-testing** | Component-level React tests, flaky test fixes, React patterns |
| **webapp-testing** | Browser-based E2E coverage, test stability, CI execution |
| **parallel-execution** | Coordinating parallel implementation lanes and convergence gates |
| **property-based-testing** | Randomized testing, input range validation, invariant verification |
| **verification-before-completion** | Before PRs, releases, or any completion declaration |
| **skill-creator** | Adding new skills, updating templates, or reviewing structure |
| **browser-canvas-testing** | HTML canvas elements, game objects, or clickElement failures |
| **code-review-intake** | Processing GitHub review comments and reconciling findings |
| **post-pr-review** | Post-merge cleanup, archiving tracking files, strategic assessment |
| **process-troubleshooting** | Diagnosing premature implementation, agent confusion, validation gaps, or terminal stalls |
| **bdd-scenarios** | Structured Given/When/Then scenario authoring and CE Gate coverage checks |
| **provenance-gate** | First-contact issue-framing assessment for cold pickups |
| **session-memory-contract** | Session-state survival labels, canonical mechanisms, and cross-tool handoff rules |
| **session-startup** | Automatic startup cleanup guard for new conversations |
| **terminal-hygiene** | Terminal and test execution guardrails for Agent Orchestra workflows |

> **VS Code 1.108+**: Skills are auto-discovered from `skills/` (repo root) when `chat.useAgentSkills` is enabled.

---

## Configuration Files

| File | Purpose | Setup |
| ---- | ------- | ----- |
| `.github/copilot-instructions.md` | Project context, tech stack, conventions | Generated by `/setup` or created manually |
| `.github/architecture-rules.md` | Layer rules, dependency rules, naming | Generated by `/setup` or created manually |
| `skills/safe-operations/SKILL.md` | Universal file-operation safety rules and issue-creation patterns (priority labels, improvement-first decision) | Included — auto-discovered from `skills/` when agent skills are enabled |
| `agents/*.agent.md` | Agent definitions | Ready to use, customize as needed |
| `skills/*/SKILL.md` | Domain knowledge | Ready to use, add your own |

---

## Examples

Three complete filled-in examples showing what your config files should look like:

| Stack | Location |
|-------|----------|
| Spring Boot (Java) | `examples/spring-boot-microservice/` |
| Express (TypeScript) | `examples/nodejs-typescript/` |
| FastAPI (Python) | `examples/python/` |

---

## Global Setup (Optional): Use Agents Across All Repositories

You can make all agents available globally in VS Code — not just in repos that have cloned this template — by adding this setting to your VS Code user settings (`Ctrl+,` &rarr; open `settings.json`):

```json
{
  "chat.agentFilesLocations": [
    "/path/to/your/agent-orchestra/agents"
  ]
}
```

Replace `/path/to/your/agent-orchestra` with the absolute path to where you cloned this repo. VS Code will load agent definitions from that folder for all workspaces.

This path-based setup only loads agent definitions. It does not load the plugin manifests or their `hooks.json` files, so automatic session-start cleanup and plugin release-hygiene prompts remain plugin-only behavior.

<!-- legacy-path -->
> **Upgrading from v1.13 or earlier?** Agents lived at `.github/agents/` before v1.14. If your `settings.json` still points at `/path/to/your/agent-orchestra/.github/agents`, update it to `/path/to/your/agent-orchestra/agents`. See [CUSTOMIZATION.md — Migrating from pre-1.14 layouts](CUSTOMIZATION.md#migrating-from-pre-114-layouts-issue-367).
<!-- /legacy-path -->

> **Warning**: VS Code loads agents additively from all configured sources — there is no name-based deduplication. If you add a global path **and** also have the plugin installed, or if a project workspace also has `agents/` at the repo root, you will see duplicate agents in the chat picker. Choose one source: either set a global path (above) **or** install the plugin, not both. If you're seeing duplicates, see [CUSTOMIZATION.md — Troubleshooting](CUSTOMIZATION.md#troubleshooting).

---

## Customization

See **[CUSTOMIZATION.md](CUSTOMIZATION.md)** for:

- How to generate or create your project config files
- Adding domain-specific skills
- Tweaking agent behaviors
- Organization-level agent setup

See **[CONTRIBUTING.md](CONTRIBUTING.md)** for recommended VS Code settings.

---

## Repository Structure

```text
agents/                  # Agent definitions (repo root)
skills/                  # Skill definitions (repo root)

.github/
├── copilot-instructions.md  # Your project context (generate via /setup)
├── architecture-rules.md    # Your architecture rules (generate via /setup)
├── instructions/        # Output format and PR review guidelines
├── prompts/             # Slash command prompt files
├── scripts/             # Post-merge cleanup and session detector
└── templates/           # Implementation plan template

plugin.json              # VS Code/Copilot plugin manifest at repo root (paths ./agents/ + ./skills/)

.claude-plugin/
├── plugin.json          # Claude Code plugin manifest (metadata-only; auto-discovers repo-root agents/ + skills/)
└── marketplace.json     # Claude Code marketplace catalog (enables /plugin marketplace add Grimblaz/agent-orchestra)

examples/
├── spring-boot-microservice/   # Java / Spring Boot example
├── nodejs-typescript/          # TypeScript / Express example
└── python/                     # Python / FastAPI example

Documents/
├── Design/              # Design documents (created by agents)
├── Decisions/           # Architecture Decision Records
└── Development/         # Testing strategy and development guides
```

---

## Migrating from copilot-orchestra

v2.0.0 renames the repo from `copilot-orchestra` to `agent-orchestra` and removes the previously-required `COPILOT_ORCHESTRA_ROOT` / `WORKFLOW_TEMPLATE_ROOT` environment variables. The session-startup script now self-resolves its repo root via `$PSScriptRoot`.

### 1. Remove the obsolete environment variables (optional cleanup)

The detector script ignores these vars now — you can leave them set or unset without effect. To clean up:

**Windows (permanent)**:

```powershell
[System.Environment]::SetEnvironmentVariable('COPILOT_ORCHESTRA_ROOT', $null, 'User')
[System.Environment]::SetEnvironmentVariable('WORKFLOW_TEMPLATE_ROOT', $null, 'User')
```

**macOS/Linux** (also remove any matching `export` lines from your shell profile):

```bash
unset COPILOT_ORCHESTRA_ROOT
unset WORKFLOW_TEMPLATE_ROOT
```

### 2. Update your VS Code plugin settings

1. **Uninstall the old plugin**: In the Extensions view (`Ctrl+Shift+X`), search `@agentPlugins copilot-orchestra` and uninstall it.
2. **Update settings**: Change the `chat.plugins.marketplaces` entry in your VS Code user `settings.json` to `["Grimblaz/agent-orchestra"]`.
3. **Install the new plugin**: Search `@agentPlugins agent-orchestra` in the Extensions view and install it.

### 3. Update Claude Code plugin (if installed)

Reinstall the plugin from the new marketplace path:

```text
/plugin marketplace add Grimblaz/agent-orchestra
/plugin install agent-orchestra@agent-orchestra
```

### 4. Git remote (no action needed)

GitHub automatically redirects `github.com/Grimblaz/copilot-orchestra` to the new URL. Existing clones and remotes continue to work without any changes — though running `git remote set-url` with the new name avoids the redirect hop.

### 5. Rename `copilot-orchestra-repo` in `.github/copilot-instructions.md`

If your downstream repo has a `copilot-orchestra-repo:` field in `.github/copilot-instructions.md` (used by the Process-Review upstream-gotcha flow), rename it to `agent-orchestra-repo:`. Process-Review reads both names during the transition — the legacy key continues to work — but new injections (via `/setup`) use the new name, and a future release will drop the legacy fallback. One-line change:

```text
# Before
copilot-orchestra-repo: Grimblaz/copilot-orchestra

# After
agent-orchestra-repo: Grimblaz/agent-orchestra
```

---

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Ways to help:

- Report issues with agent definitions
- Share prompt or workflow improvements
- Add new skill definitions
- Improve the examples

## License

Available under the terms in the LICENSE file.
