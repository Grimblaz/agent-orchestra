# Copilot Workflow Template

[![Version](https://img.shields.io/badge/version-v1.5.0-blue.svg)](../../releases)
[![Ready for Production](https://img.shields.io/badge/status-production%20ready-green.svg)](../../releases)

A multi-agent workflow system for GitHub Copilot that orchestrates AI-assisted software development across specialized agents.

## Install as Plugin (VS Code 1.110+)

> **Experimental**: Agent plugins are available in VS Code 1.110 as an experimental feature. Plugin distribution is the fastest way to get started with no cloning required.

### Quick Setup (Plugin)

1. **Enable plugins** — Add to VS Code user settings (`Ctrl+Shift+P` → "Open User Settings (JSON)"):

   ```json
   {
     "chat.plugins.enabled": true,
     "chat.plugins.marketplaces": ["Grimblaz/workflow-template"]
   }
   ```

2. **Install** — In the Extensions view (`Ctrl+Shift+X`), search `@agentPlugins workflow-template` and install.
3. **Use** — All 13 agents and 14 skills are immediately available in VS Code Chat.

**What's included in the plugin**: 13 agents, 14 skills, and 2 slash commands (`/setup`, `/start-issue`).

**What requires clone/fork**: Instruction files (`.github/instructions/`), hooks (`session-cleanup.json`), and project templates are not distributed via the plugin — they are auto-discovered by VS Code when you clone or fork the repo.

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
- **Phase 1** — One-time user setup: sets `WORKFLOW_TEMPLATE_ROOT` and adds agents, skills, hooks, and instructions to your VS Code settings. Skip if already configured.
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
| Pick up a GitHub issue and design a solution | `@Issue-Designer` |
| Create an implementation plan for an issue | `@Issue-Planner` |
| Implement a planned feature end-to-end | `@Code-Conductor` |
| Review code and identify risks | `@Code-Critic` |
| Respond to a code review | `@Code-Review-Response` |

### Core Workflow

```text
Issue → @Issue-Designer → @Issue-Planner → @Code-Conductor → PR
```

1. **@Issue-Designer** — picks up the issue, explores the design space, updates the issue body with a design
2. **@Issue-Planner** — creates a step-by-step implementation plan
3. **@Code-Conductor** — reads the plan, delegates to internal specialist agents, creates a merge-ready PR

### Example: Start a feature from scratch

```markdown
@Issue-Designer Please design issue #42.
```

Then, once the design is in the issue:

```markdown
@Code-Conductor Issue #42 is designed and planned. Please implement it.
```

---

## Agent Reference

### Agents you interact with directly (5)

| Agent | What it does |
|-------|-------------|
| **Issue-Designer** | Design exploration and issue management |
| **Issue-Planner** | Multi-step implementation plan creation |
| **Code-Conductor** | End-to-end orchestration of implementation |
| **Code-Critic** | Adversarial code review and risk discovery |
| **Code-Review-Response** | Judges review feedback and delegates fixes |

### Internal agents (called automatically by Code-Conductor)

These agents are hidden from the picker (`user-invokable: false`) and are used automatically during `@Code-Conductor` workflows:

Code-Smith, Test-Writer, Refactor-Specialist, Doc-Keeper, Research-Agent, Process-Review, Specification, UI-Iterator

> See `.github/agents/` for full definitions of all 13 agents.

---

## Skills Framework

Skills are domain-specific knowledge packages in `.github/skills/` that agents load on demand:

| Skill | When it's used |
|-------|---------------|
| **test-driven-development** | Writing tests, red-green-refactor |
| **systematic-debugging** | Investigating complex bugs |
| **software-architecture** | Evaluating design decisions |
| **brainstorming** | Exploring requirements or trade-offs |
| **frontend-design** | Building UI components |
| **ui-testing** | React component test strategies |
| **webapp-testing** | Playwright end-to-end tests |
| **parallel-execution** | Running parallel/serial implementation lanes |
| **property-based-testing** | Incremental randomized property verification |
| **verification-before-completion** | Pre-PR readiness checks |
| **skill-creator** | Adding new skills to the framework |
| **browser-canvas-testing** | Canvas game browser interaction (VS Code native tools) |
| **code-review-intake** | GitHub review intake mode, Code-Critic finding reconciliation |
| **post-pr-review** | Post-merge cleanup, archiving tracking files, pre-merge assessment |

> **VS Code 1.108+**: Skills are auto-discovered from `.github/skills/` when `chat.useAgentSkills` is enabled.

---

## Configuration Files

| File | Purpose | Setup |
| ---- | ------- | ----- |
| `.github/copilot-instructions.md` | Project context, tech stack, conventions | Generated by `/setup` or created manually |
| `.github/architecture-rules.md` | Layer rules, dependency rules, naming | Generated by `/setup` or created manually |
| `.github/instructions/safe-operations.instructions.md` | Universal file-operation safety rules and issue-creation patterns (priority labels, improvement-first decision) | Included — loaded automatically via `chat.instructionsFilesLocations` |
| `.github/agents/*.agent.md` | Agent definitions | Ready to use, customize as needed |
| `.github/skills/*/SKILL.md` | Domain knowledge | Ready to use, add your own |
| `.github/hooks/session-cleanup.json` | VS Code `SessionStart` hook — prompts for post-merge cleanup | Ready to use |

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
    "/path/to/your/workflow-template/.github/agents"
  ]
}
```

Replace `/path/to/your/workflow-template` with the absolute path to where you cloned this repo. VS Code will load agent definitions from that folder for all workspaces.

> **Tip**: Use this when you want the workflow agents available in all your projects, even ones that haven't cloned this template. You can also add both a global path and a per-project `.github/agents/` folder — VS Code merges them.

---

## Claude Code Support

This template also supports [Claude Code](https://docs.anthropic.com/en/docs/claude-code) (CLI agent). Both tools coexist — they use separate configuration paths and do not interfere with each other.

- `CLAUDE.md` at the project root provides Claude Code with project context and a phased workflow
- `.claude/commands/` contains slash commands: `start-issue`, `implement`, `review`, `setup`
- Agent definitions and skills in `.github/` are referenced as role guides — no duplication

See [CUSTOMIZATION.md](CUSTOMIZATION.md#claude-code-support) for details on the file mapping, slash commands, and how to set up Claude Code for your target project.

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
.claude/
└── commands/            # Claude Code slash commands (start-issue, implement, review, setup)

.github/
├── agents/              # Agent definitions (used by Copilot, referenced by Claude Code)
├── copilot-instructions.md  # Your project context (generate via /setup)
├── architecture-rules.md    # Your architecture rules (generate via /setup)
├── hooks/               # Session lifecycle hooks (SessionStart)
├── instructions/        # Output format and PR review guidelines
├── prompts/             # setup.prompt.md and start-issue.md
├── scripts/             # Post-merge cleanup and session detector
├── skills/              # Skill definitions
└── templates/           # Implementation plan template

examples/
├── spring-boot-microservice/   # Java / Spring Boot example
├── nodejs-typescript/          # TypeScript / Express example
└── python/                     # Python / FastAPI example

Documents/
├── Design/              # Design documents (created by agents)
├── Decisions/           # Architecture Decision Records
└── Development/         # Testing strategy and development guides

CLAUDE.md                # Claude Code project instructions
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
