# Customization Guide

This guide explains how to configure the workflow template for your project.

## Quick Option: Setup Wizard

Open GitHub Copilot Chat, run the **`/setup`** command. Setup runs in six phases:

> **Recommended model**: Claude Opus — the setup wizard benefits from deep reasoning for architecture and tech stack decisions. *(o3 or GPT-4o also work well if Opus is unavailable.)*

| Phase | What it does | Skip available? |
|-------|-------------|------------------|
| **Phase 0** — Prerequisites | Auto-detects VS Code version, pwsh, git, and gh CLI; checks for empty workspace (creates `README.md` placeholder if needed) and wrong workspace | No — runs automatically |
| **Phase 1** — User Setup | Sets `WORKFLOW_TEMPLATE_ROOT` and VS Code settings (one-time, machine-level) | Yes — skips if already configured |
| **Phase 2** — Project Basics | Collects project name, language, framework, database | Yes — skips if `copilot-instructions.md` already exists |
| **Phase 3** — Architecture | Collects architecture style, conventions, build tool | Yes — skips if `architecture-rules.md` already exists |
| **Phase 4** — Commands | Collects build, run, test, lint, and quick-validate commands | Yes — offered when Phases 2, 3, and 5 are all skipped |
| **Phase 5** — Scaffolding | Generates `.gitignore` additions, `.vscode/` defaults, `Documents/` structure | Yes — opt-in |

If you've already completed user setup (Phase 1) for another repo, the wizard detects this and skips straight to Phase 2.

> **Note**: `/setup` works in any repo — creating from the GitHub template is optional. If your workspace is brand-new and completely empty, don't worry — Phase 0 will automatically create a `README.md` placeholder. (VS Code's workspace context provider crashes on zero-file workspaces; Phase 0 handles this.)

## Manual Option: Create the Config Files

### 1. `.github/copilot-instructions.md`

This file tells agents about your project. Create it with the following sections:

- **Project name** and **overview** — what your project does
- **Technology stack** — language, framework, database, build tool, test framework
- **Architecture** — describe your layers and include a text diagram
- **Key conventions** — naming rules, patterns your agents must follow
- **Build & run commands** — how to build, run, and test

See `examples/` for three complete filled-in examples (Spring Boot, TypeScript, Python).

### 2. `.github/architecture-rules.md`

This file defines structural rules for your codebase. Include:

- **Layer structure** — a table of layers and their responsibilities
- **Dependency rules** — what's allowed and forbidden
- **Testing rules** — per-layer testing approach
- **File & naming conventions** — file patterns and directory structure

### 3. Agent Definitions (Optional)

Agents in `.github/agents/` work without customization. If you want to tweak behavior:

- Agent files use YAML frontmatter (`---`) with fields like `name`, `description`, `tools`, `handoffs`
- Focus on adjusting a specific agent's responsibilities or interaction patterns
- Keep changes targeted — agents are already tuned for general use

### 4. Add Domain Skills (Optional)

Create project-specific knowledge packages in `.github/skills/`:

```bash
# In Copilot Chat:
@skill-creator Help me create a skill for [your domain]
```

Each skill needs a `SKILL.md` file with `name` and `description` frontmatter. VS Code 1.108+ auto-discovers skills when `chat.useAgentSkills` is enabled.

### 5. Organization-Level Agents (Optional)

To share agents across all repositories in your org:

- Place agent files in an `agents/` folder at the root of your org's `.github` or `.github-private` repository
- Repository-level agents in `.github/agents/` override org defaults

### 6. Session Cleanup Hook (Optional)

> **Tip**: If you're using the setup wizard (`/setup`), Phase 1 handles `WORKFLOW_TEMPLATE_ROOT` and the `chat.hookFilesLocations` setting automatically.
>
> The steps below are the manual equivalent — follow them if you prefer to configure without the wizard, or if you need to adjust an existing configuration.

The workflow-template includes a `SessionStart` hook that detects stale feature branches and leftover tracking files after a PR is merged, and prompts you to run cleanup at the start of your next VS Code Copilot session.

**Setup — two steps:**

**Step 1**: Add to your user VS Code settings (`settings.json`):

```json
{
  "chat.hookFilesLocations": ["/absolute/path/to/workflow-template/.github/hooks"],
  "chat.agentFilesLocations": ["/absolute/path/to/workflow-template/.github/agents"],
  "chat.agentSkillsLocations": ["/absolute/path/to/workflow-template/.github/skills"],
  "chat.instructionsFilesLocations": {
    "/absolute/path/to/workflow-template/.github/instructions": true
  },
  "chat.promptFilesLocations": {
    "/absolute/path/to/workflow-template/.github/prompts": true
  }
}
```

| Setting | What it enables |
|---|---|
| `chat.hookFilesLocations` | Session cleanup hook (detects stale branches after PR merge) |
| `chat.agentFilesLocations` | All workflow agents available in every repository |
| `chat.agentSkillsLocations` | All workflow skills available in every repository |
| `chat.instructionsFilesLocations` | Shared instruction files apply across all your repositories |
| `chat.promptFilesLocations` | Shared prompt files (e.g. `/setup`) available in every repository |

> **Windows path**: Use forward slashes or escaped backslashes in the JSON value, e.g. `"C:/Users/you/workflow-template/.github/hooks"` or `"C:\\Users\\you\\workflow-template\\.github\\hooks"`. Apply the same format to all five settings above.

**Step 2**: Set the `WORKFLOW_TEMPLATE_ROOT` environment variable to the absolute path of your local workflow-template clone. Without this, the hook will display an error message instead of running.

**Windows (permanent — recommended)**:

Set via System Properties > Advanced > Environment Variables, or from a PowerShell terminal:

```powershell
[System.Environment]::SetEnvironmentVariable('WORKFLOW_TEMPLATE_ROOT', 'C:\path\to\workflow-template', 'User')
```

This persists across all sessions, including VS Code launched from the Start Menu or GUI.

**Windows (PowerShell profile — session-scope only)**:

Add to your PowerShell profile (`$PROFILE`):

```powershell
$env:WORKFLOW_TEMPLATE_ROOT = "C:\path\to\workflow-template"
```

> **Note**: Profile-set variables are only available in shells where the profile is loaded. VS Code launched from the Start Menu or a desktop shortcut may not run your PowerShell profile, causing the hook to display a "not set" error. Use the permanent approach above if this happens.

**macOS/Linux (shell profile)**:

```bash
export WORKFLOW_TEMPLATE_ROOT="/path/to/workflow-template"
```

**What it does**: On each VS Code session start, the hook checks whether your current branch's remote has been deleted (indicating a merged PR) or whether `.copilot-tracking/` files exist for merged issues. If cleanup is needed, it prompts you to confirm before running `post-merge-cleanup.ps1`.

**Requires**: PowerShell 7+ (`pwsh`) installed on PATH and VS Code 1.109.3+.

### 7. Project Scaffolding (Phase 5 of Setup Wizard)

When you run `/setup` and opt into Phase 5, the wizard can generate starter files for your project:

| File | What it does |
|------|-------------|
| `.gitignore` additions | Appends workflow-template tracking dirs (`/.copilot-tracking/`, `/.copilot-tracking-archive/`) and optional entries (`screenshots/`, `/.playwright-mcp/`) — additive only, never removes existing lines |
| `.vscode/settings.json` | Editor defaults: `formatOnSave`, `files.exclude`, `search.exclude`; web projects also add `workbench.browser.enableChatTools: true` for VS Code 1.110+ native browser tools |
| `.vscode/extensions.json` | Empty recommendations array for you to populate |
| `.vscode/mcp.json` *(web projects, optional)* | Playwright MCP config — optional fallback for users who prefer it over VS Code 1.110+ native browser tools |
| `.github/instructions/browser-tools.instructions.md` *(web projects)* | Dev server startup rules and browser tool selection priority (native tools primary, Playwright MCP fallback), with your port and run command substituted |
| `Documents/` structure | Creates `Design/`, `Decisions/`, `Development/` subdirectories |

If any file already exists, Phase 5 asks before overwriting (`.vscode/settings.json`, `.vscode/mcp.json`) or skips silently (`.vscode/extensions.json`). `.gitignore` additions are always additive — no existing lines are removed.

## Claude Code Support

This template supports both GitHub Copilot agents and Claude Code (CLI). They use separate configuration paths and coexist without conflict.

### How It Works

Claude Code uses `CLAUDE.md` (project root) instead of `.github/copilot-instructions.md`. The `.github/agents/`, `.github/skills/`, and `.github/instructions/` files are shared — both tools reference them without duplication. However, project metadata (overview, tech stack, build commands, architecture summary, and conventions) is intentionally included in both `CLAUDE.md` and `.github/copilot-instructions.md` because each tool needs this context independently.

| Copilot | Claude Code |
|---------|-------------|
| `.github/copilot-instructions.md` | `CLAUDE.md` (project root) |
| `.github/agents/*.agent.md` | Referenced as role guides in `CLAUDE.md` workflow |
| `.github/skills/*/SKILL.md` | Referenced directly — Claude Code reads them on demand |
| `.github/instructions/*.instructions.md` | Referenced directly — listed in `CLAUDE.md` |
| `.github/prompts/setup.prompt.md` | `.claude/commands/setup.md` |
| `.github/prompts/start-issue.md` | `.claude/commands/start-issue.md` |
| `@Code-Conductor` (multi-agent) | `/project:implement` (phased single-agent) |

### Slash Commands

| Command | Purpose |
|---------|---------|
| `/project:start-issue {number}` | Begin work on a GitHub issue (branch, research, plan) |
| `/project:implement` | Execute an approved implementation plan |
| `/project:review` | Adversarial self-review across 7 perspectives |
| `/project:setup` | Configure a target project (generates both Copilot and Claude Code files) |

### Setting Up Claude Code for a Target Project

**Option A**: Run `/project:setup` in Claude Code. It collects your project details and generates both `.github/copilot-instructions.md` and `CLAUDE.md`.

**Option B**: Create `CLAUDE.md` manually. See `examples/` for three filled-in examples (Spring Boot, TypeScript, Python) — each directory contains both `copilot-instructions.md` (Copilot) and `CLAUDE.md` (Claude Code).

### Key Difference: Single-Agent Workflow

Copilot uses multiple specialized agents (Code-Conductor delegates to Code-Smith, Test-Writer, etc.). Claude Code is a single agent that follows a phased workflow:

1. **Plan** — research and draft implementation plan
2. **Implement** — execute the plan step by step
3. **Test** — ensure test coverage
4. **Refactor** — review modified files for improvements
5. **Review** — adversarial self-review (7 perspectives)
6. **Document** — update design docs and changelog
7. **Create PR** — push and open PR with evidence

Each phase references the corresponding `.github/agents/*.agent.md` file as a role guide for standards and checklists.

## Troubleshooting

**Agents not following instructions?**

- Verify `.github/copilot-instructions.md` exists and has real project content
- Check agent files have valid YAML frontmatter with `---` delimiters

**Skills not being used?**

- Confirm `SKILL.md` has `name` and `description` frontmatter
- Enable `chat.useAgentSkills` in VS Code settings (requires VS Code 1.108+)

**Need to debug agent behavior in detail?**

VS Code 1.110+ includes an Agent Debug panel that gives real-time visibility into agent execution:

- Open it with: `Developer: Open Agent Debug Panel`
- Shows loaded customizations (instructions, skills, agent files), tool calls, system prompts, and agent events as they happen
- Available since VS Code 1.110 (supersedes the earlier Diagnostics chat action)
- Especially useful when agents appear to ignore instructions or tools — confirm the relevant files are actually loaded
