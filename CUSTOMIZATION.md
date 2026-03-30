# Customization Guide

This guide explains how to configure the workflow template for your project.

## Distribution Options

This template supports two distribution models:

| Model | How to Install | What You Get |
|-------|---------------|--------------|
| **Plugin** (VS Code 1.110+) | Add marketplace to settings + install from Extensions view | 14 agents, 16 skills, 9 slash commands (`/setup`, `/start-issue`, `/design`, `/plan`, `/implement`, `/review`, `/polish`, `/experience`, `/orchestrate`) — instantly available |
| **Clone/Fork** | `git clone` or use as template | Everything above PLUS instruction files (auto-loaded by VS Code, incl. session-startup), project templates, and examples |

### Plugin Installation

1. Add to VS Code user settings:

   ```json
   {
     "chat.plugins.enabled": true,
     "chat.plugins.marketplaces": ["Grimblaz/copilot-orchestra"]
   }
   ```

2. Open Extensions view (`Ctrl+Shift+X`), search `@agentPlugins copilot-orchestra`, install.

> **Note**: If you use the plugin, you will not receive **automatic** loading of `.github/instructions/` files (the plugin does not distribute these). The session-startup check requires `COPILOT_ORCHESTRA_ROOT` (or the fallback `WORKFLOW_TEMPLATE_ROOT`) — it silently skips for users who haven't set either variable. For full instruction support, use the clone/fork model and enable `chat.instructionsFilesLocations` — or combine the plugin with `chat.instructionsFilesLocations` pointing to a local clone (see the Warning callout below and the wizard's Option 1).

<!-- blockquote separator: prevents Note and Warning from merging in GitHub Markdown -->

> **Warning**: Choose **one source** for agents — either the plugin **or** a clone/global path, not both.
>
> | Setting | Safe with plugin? | Why |
> |---------|-----------------|-----|
> | `chat.agentFilesLocations` | ❌ No | Plugin already distributes agents — combining creates duplicates |
> | `chat.agentSkillsLocations` | ✅ Yes | Skills handled by priority — combining with plugin does not create duplicates |
> | `chat.instructionsFilesLocations` | ✅ Yes | Plugin does NOT distribute instruction files — no duplication |
> | `chat.promptFilesLocations` | ✅ Likely | Plugin distributes prompts as slash commands (not via `promptFilesLocations`); deduplication is expected but unconfirmed on VS Code 1.110 |
>
> If you're seeing duplicate agents in the chat picker, see the **Troubleshooting** section below.

---

## Quick Option: Setup Wizard

Open GitHub Copilot Chat, run the **`/setup`** command. Setup runs in six phases:

> **Recommended model**: Claude Opus — the setup wizard benefits from deep reasoning for architecture and tech stack decisions. *(o3 or GPT-4o also work well if Opus is unavailable.)*

| Phase | What it does | Skip available? |
|-------|-------------|------------------|
| **Phase 0** — Prerequisites | Auto-detects VS Code version, pwsh, git, and gh CLI; checks for empty workspace (creates `README.md` placeholder if needed) and wrong workspace | No — runs automatically |
| **Phase 1** — User Setup | Sets `COPILOT_ORCHESTRA_ROOT` and VS Code settings (one-time, machine-level) | Yes — skips if already configured |
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

### 6. Session Startup Instruction (Optional)

> **Tip**: If you're using the setup wizard (`/setup`), Phase 1 handles `COPILOT_ORCHESTRA_ROOT` and all VS Code settings automatically.
>
> The steps below are the manual equivalent — follow them if you prefer to configure without the wizard, or if you need to adjust an existing configuration.

The Copilot Orchestra includes a session startup check (inline in `.github/copilot-instructions.md`) that applies a session-memory run-once guard before any automatic detector invocation. The guard uses the marker `/memories/session/session-startup-check-complete.md`. The first automatic check in a conversation looks for stale feature branches and leftover issue-scoped tracking files, records that marker after the automatic startup check runs, and prevents repeated prompts from later agent hops even if cleanup is declined. Persistent calibration data under `.copilot-tracking/calibration/` is not cleanup work. The full edge-case details are in `.github/instructions/session-startup.instructions.md` (detailed reference only — the check itself runs from `.github/copilot-instructions.md`).

**Setup — two steps:**

**Step 1**: Add to your user VS Code settings (`settings.json`):

```json
{
  "chat.agentFilesLocations": ["/absolute/path/to/copilot-orchestra/.github/agents"],
  "chat.agentSkillsLocations": ["/absolute/path/to/copilot-orchestra/.github/skills"],
  "chat.instructionsFilesLocations": {
    "/absolute/path/to/copilot-orchestra/.github/instructions": true
  },
  "chat.promptFilesLocations": {
    "/absolute/path/to/copilot-orchestra/.github/prompts": true
  }
}
```

| Setting | What it enables |
|---|---|
| `chat.agentFilesLocations` | All workflow agents available in every repository |
| `chat.agentSkillsLocations` | All workflow skills available in every repository |
| `chat.instructionsFilesLocations` | Shared instruction files apply across all your repositories (includes session-startup) |
| `chat.promptFilesLocations` | Shared prompt files (e.g. `/setup`) available in every repository |

> **Windows path**: Use forward slashes or escaped backslashes in the JSON value, e.g. `"C:/Users/you/copilot-orchestra/.github/instructions"`. Apply the same format to all four settings above.
>
> **Migration note**: If you previously configured `chat.hookFilesLocations`, you can safely remove it — hooks have been replaced by the session startup check (inline in `.github/copilot-instructions.md`).

**Step 2**: Set the `COPILOT_ORCHESTRA_ROOT` environment variable to the absolute path of your local copilot-orchestra clone. Without this, the session startup check will not run cleanup scripts. (If you already have `WORKFLOW_TEMPLATE_ROOT` set, it works as a fallback — no immediate action needed.)

**Windows (permanent — recommended)**:

Set via System Properties > Advanced > Environment Variables, or from a PowerShell terminal:

```powershell
[System.Environment]::SetEnvironmentVariable('COPILOT_ORCHESTRA_ROOT', 'C:\path\to\copilot-orchestra', 'User')
```

This persists across all sessions, including VS Code launched from the Start Menu or GUI.

**Windows (PowerShell profile — session-scope only)**:

Add to your PowerShell profile (`$PROFILE`):

```powershell
$env:COPILOT_ORCHESTRA_ROOT = "C:\path\to\copilot-orchestra"
```

> **Note**: Profile-set variables are only available in shells where the profile is loaded. VS Code launched from the Start Menu or a desktop shortcut may not run your PowerShell profile, causing `COPILOT_ORCHESTRA_ROOT` to appear unset. Use the permanent approach above if this happens.

**macOS/Linux (shell profile)**:

```bash
export COPILOT_ORCHESTRA_ROOT="/path/to/copilot-orchestra"
```

**What it does**: At the start of each conversation, the first automatic startup check uses the session-memory marker `/memories/session/session-startup-check-complete.md` to ensure the detector runs only once automatically per conversation. That automatic check looks for a deleted upstream branch (indicating a merged PR) or stale issue-scoped `.copilot-tracking/` files for merged issues. Persistent calibration data is excluded from cleanup detection. If cleanup is needed, it prompts you to confirm before running `post-merge-cleanup.ps1`. If neither root environment variable is set, `pwsh` is unavailable, the detector script is missing, or the detector returns non-JSON output, the automatic check skips silently. If session-memory access fails, the detector still runs; explicit manual detector runs remain available after the automatic guard fires.

**Requires**: PowerShell 7+ (`pwsh`) installed on PATH and `COPILOT_ORCHESTRA_ROOT` (or `WORKFLOW_TEMPLATE_ROOT`) set.

### 7. Project Scaffolding (Phase 5 of Setup Wizard)

When you run `/setup` and opt into Phase 5, the wizard can generate starter files for your project:

| File | What it does |
|------|-------------|
| `.gitignore` additions | Appends copilot-orchestra tracking dirs (`/.copilot-tracking/`, `/.copilot-tracking-archive/`) and optional entries (`screenshots/`, `/.playwright-mcp/`) — additive only, never removes existing lines |
| `.vscode/settings.json` | Editor defaults: `formatOnSave`, `files.exclude`, `search.exclude`; web projects also add `workbench.browser.enableChatTools: true` for VS Code 1.110+ native browser tools |
| `.vscode/extensions.json` | Empty recommendations array for you to populate |
| `.vscode/mcp.json` *(web projects, optional)* | Playwright MCP config — optional fallback for users who prefer it over VS Code 1.110+ native browser tools |
| `.github/instructions/browser-tools.instructions.md` *(web projects)* | Dev server startup rules and browser tool selection priority (native tools primary, Playwright MCP fallback), with your port and run command substituted |
| `Documents/` structure | Creates `Design/`, `Decisions/`, `Development/` subdirectories |

If any file already exists, Phase 5 asks before overwriting (`.vscode/settings.json`, `.vscode/mcp.json`) or skips silently (`.vscode/extensions.json`). `.gitignore` additions are always additive — no existing lines are removed.

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

---

**Seeing duplicate agents in the picker?**

VS Code loads agents additively from all configured sources — there is no name-based deduplication. Any of these combinations will cause every agent to appear twice:

1. **Plugin installed + working in a cloned repo** — the plugin loads agents from GitHub; the workspace `.github/agents/` folder loads them again. Fix: uninstall the plugin, or close the copilot-orchestra folder from your VS Code workspace (not recommended — prefer uninstalling the plugin if you want the clone experience).
2. **Plugin installed + `chat.agentFilesLocations` in settings** — two sources, two copies of every agent. Fix: remove `chat.agentFilesLocations` from your VS Code user settings (keep `chat.agentSkillsLocations`, `chat.instructionsFilesLocations`, and `chat.promptFilesLocations` — those are safe).
3. **Global `chat.agentFilesLocations` + working in a repo with `.github/agents/`** — global path and workspace auto-discovery both find the agents. Fix: remove `chat.agentFilesLocations` from user settings if you only need agents in the copilot-orchestra clone.

> **Quick fix checklist**: Open VS Code user `settings.json` (`Ctrl+,` → open `settings.json`) and check for `chat.agentFilesLocations` and `chat.plugins.marketplaces`. Having entries for both plugin and clone-path settings is the most common cause of duplicates.
