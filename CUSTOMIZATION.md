# Customization Guide

This guide explains how to configure the workflow template for your project.

## Distribution Options

This template supports two distribution models:

| Model | How to Install | What You Get |
|-------|---------------|--------------|
| **Plugin** (VS Code 1.110+) | Add marketplace to settings + install from Extensions view | 14 agents, 39 skills, and 10 shipped command files (`/design`, `/experience`, `/plan`, `/orchestrate`, `/polish`, `/orchestra:review`, `/orchestra:review-lite`, `/orchestra:review-prosecute`, `/orchestra:review-defend`, `/orchestra:review-judge`) — instantly available |
| **Clone/Fork** | `git clone` or use as template | Everything above PLUS editable prompts, project templates, examples, and any repo-local instruction files you choose to keep under `.github/instructions/` |

### Plugin Installation

1. Add to VS Code user settings:

   ```json
   {
     "chat.plugins.enabled": true,
     "chat.plugins.marketplaces": ["Grimblaz/agent-orchestra"]
   }
   ```

2. Open Extensions view (`Ctrl+Shift+X`), search `@agentPlugins agent-orchestra`, install.

**Note**: If you use the plugin, you still receive the shared workflow guidance that now ships through skills, including `safe-operations`, `step-commit`, `pre-commit-formatting`, and `tracking-format`. `chat.instructionsFilesLocations` is only needed for repo-local instruction files that are intentionally still instructions, such as generated consumer files under `.github/instructions/`. The session-startup check now self-resolves its repo root via `$PSScriptRoot` — no environment variable is required. No extra startup or provenance trigger section is required in your project's `copilot-instructions.md`; the portable trigger wiring now lives in the shipped agent files. Claude Code's native plugin surface now includes shells for all specialist agents, including `Process-Review`, `UI-Iterator`, `Research-Agent`, and `Specification`, so no Claude-side specialist fallback setup is required.

<!-- blockquote separator: prevents Note and Warning from merging in GitHub Markdown -->

> **Warning**: Choose **one source** for agents — either the plugin **or** a clone/global path, not both.
>
> | Setting | Safe with plugin? | Why |
> |---------|-----------------|-----|
> | `chat.agentFilesLocations` | ❌ No | Plugin already distributes agents — combining creates duplicates |
> | `chat.agentSkillsLocations` | ✅ Yes | Skills handled by priority — combining with plugin does not create duplicates |
> | `chat.instructionsFilesLocations` | ✅ Yes | Use only for repo-local instruction files that remain under `.github/instructions/`; migrated hub workflow guidance now ships via skills |
> | `chat.promptFilesLocations` | ✅ Likely | Plugin distributes prompts as slash commands (not via `promptFilesLocations`); deduplication is expected but unconfirmed on VS Code 1.110 |
>
> If you're seeing duplicate agents in the chat picker, see the **Troubleshooting** section below.

#### What works out of the box vs. what you need to set up yourself

| Feature | Plugin | What you need |
|---------|--------|---------------|
| All 14 agents in chat picker | ✅ Works | Nothing |
| All 39 skills in Configure Skills menu | ✅ Works | Nothing |
| 10 shipped command files (`/design`, `/experience`, `/plan`, `/orchestrate`, `/polish`, `/orchestra:review`, `/orchestra:review-lite`, `/orchestra:review-prosecute`, `/orchestra:review-defend`, `/orchestra:review-judge`) | ✅ Works | Nothing |
| Shared workflow skills (`safe-operations`, `step-commit`, etc.) | ✅ Works | Nothing |
| Session startup check | ✅ Works | Nothing (self-resolves via `$PSScriptRoot` — no env var required in v2.0.0+) |
| Project-aware agent guidance | ⚠️ Generic only | Copy `copilot-instructions.md` and `architecture-rules.md` to your project's `.github/` directory |
| `chat.instructionsFilesLocations` rules | ⚠️ Not distributed | Add `chat.instructionsFilesLocations` pointing to your clone if needed |
| Scripts from `.github/scripts/` (e.g. post-PR cleanup) | ✅ Works | Nothing (scripts self-resolve their plugin-cache path) |
| `/release` slash command | ❌ Intentionally excluded | Clone or fork the repo (maintainer workflow only) |

#### Script portability for plugin users

All skills' PowerShell scripts self-resolve their sibling paths via `$PSScriptRoot`, so they work identically whether invoked from the plugin cache or a clone/fork. This is the v2.0.0 design — no environment variable configuration is required.

If a skill's script produces no output when invoked from the plugin, file an issue with the skill name and reproduction steps; silent failure is a regression, not an expected limitation.

<!-- migration-note-begin -->
### Migrating from pre-1.14 layouts (issue #367)

Starting in v1.14.0, agents and skills live at the repo root (`agents/` and `skills/`) rather than under `.github/`. This lets Claude Code auto-discover them via `.claude-plugin/plugin.json` while Copilot loads them through `plugin.json` (also at the repo root — relocated from `.github/plugin.json` in v2.0.0 so Copilot paths read as `./agents/` + `./skills/{name}/` without `..` escapes). Existing consumers must:

1. Remove any `chat.agentFilesLocations` entry pointing at `.github/agents` from `settings.json`.
2. If a consumer referenced `$copilotRoot/.github/skills/...` runtime paths, update to `$copilotRoot/skills/...`.
3. Reinstall the orchestra as a plugin in both tools.

<!-- legacy-path -->
Example of a pre-1.14 `settings.json` entry that should be removed:

```json
{
  "chat.agentFilesLocations": ["/absolute/path/to/agent-orchestra/.github/agents"]
}
```
<!-- /legacy-path -->
<!-- migration-note-end -->

---

## Quick Option: Setup Wizard

Open GitHub Copilot Chat, run the **`/setup`** command. Setup runs in six phases:

> **Recommended model**: Claude Opus — the setup wizard benefits from deep reasoning for architecture and tech stack decisions. *(o3 or GPT-4o also work well if Opus is unavailable.)*

| Phase | What it does | Skip available? |
|-------|-------------|------------------|
| **Phase 0** — Prerequisites | Auto-detects VS Code version, pwsh, git, and gh CLI; checks for empty workspace (creates `README.md` placeholder if needed) and wrong workspace | No — runs automatically |
| **Phase 1** — User Setup | Configures VS Code `chat.*Locations` settings (one-time, machine-level) | Yes — skips if already configured |
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

Agents in `agents/` (at the repo root) work without customization. If you want to tweak behavior:

- Agent files use YAML frontmatter (`---`) with fields like `name`, `description`, `tools`, `handoffs`
- Focus on adjusting a specific agent's responsibilities or interaction patterns
- Keep changes targeted — agents are already tuned for general use

### 4. Add Domain Skills (Optional)

Create project-specific knowledge packages in `skills/` (at the repo root):

```bash
# In Copilot Chat:
@skill-creator Help me create a skill for [your domain]
```

Each skill needs a `SKILL.md` file with `name` and `description` frontmatter. VS Code 1.108+ auto-discovers skills when `chat.useAgentSkills` is enabled.

### 5. Organization-Level Agents (Optional)

To share agents across all repositories in your org:

- Place agent files in an `agents/` folder at the root of your org's `.github` or `.github-private` repository
- Repository-level agents in `agents/` (at the repo root) override org defaults

### 6. Session Startup Check (Optional)

> **Tip**: If you're using the setup wizard (`/setup`), Phase 1 handles the VS Code settings automatically.
>
> The steps below are the manual equivalent — follow them if you prefer to configure without the wizard, or if you need to adjust an existing configuration.

The Agent Orchestra includes a plugin-distributed session startup check handled by the `session-startup` skill. It applies a session-memory run-once guard before any automatic detector invocation. The guard uses the marker `/memories/session/session-startup-check-complete.md`. The first automatic check in a conversation looks for current-branch cleanup, stale issue-scoped tracking files, sibling worktrees, orphan branches, fail-open conditions, and opt-in cleanup choices, then records that marker after the automatic startup check runs. Persistent calibration data under `.copilot-tracking/calibration/` is not cleanup work.

**Setup — one step:**

Add to your user VS Code settings (`settings.json`):

```json
{
  "chat.agentFilesLocations": ["/absolute/path/to/agent-orchestra/agents"],
  "chat.agentSkillsLocations": ["/absolute/path/to/agent-orchestra/skills"],
  "chat.promptFilesLocations": {
    "/absolute/path/to/agent-orchestra/.github/prompts": true
  }
}
```

| Setting | What it enables |
|---|---|
| `chat.agentFilesLocations` | All workflow agents available in every repository |
| `chat.agentSkillsLocations` | All workflow skills available in every repository |
| `chat.promptFilesLocations` | Shared prompt files (e.g. `/setup`) available in every repository |

> **Optional**: Add `chat.instructionsFilesLocations` only if you keep repo-local instruction files in your clone or target repo, for example generated consumer files like `.github/instructions/browser-tools.instructions.md`. It is no longer required for the migrated hub workflow guidance, which now ships via skills.
>
> **Windows path**: Use forward slashes or escaped backslashes in the JSON value, e.g. `"C:/Users/you/agent-orchestra/.github/prompts"`. Apply the same format to every path-based setting above.
>
> **Migration note**: If you previously configured `chat.hookFilesLocations`, you can safely remove it. Hooks are no longer configured through a VS Code user setting; plugin installs now load them from the shipped manifests (`plugin.json` for Copilot, `.claude-plugin/plugin.json` for Claude Code). Clone/path-based `chat.*Locations` settings continue to load agents, skills, prompts, and optional instructions, but they do not activate plugin hooks.
>
> **v2.0.0 env var removal**: Earlier versions required `COPILOT_ORCHESTRA_ROOT` (or `WORKFLOW_TEMPLATE_ROOT`) for the session startup check to locate its scripts. v2.0.0 makes the script self-resolve via `$PSScriptRoot`, so no env var configuration is needed. You can safely unset any old `COPILOT_ORCHESTRA_ROOT` / `WORKFLOW_TEMPLATE_ROOT` values — the detector ignores them now.

**What it does**: At the start of each conversation, the first automatic startup check uses the session-memory marker `/memories/session/session-startup-check-complete.md` to ensure the detector runs only once automatically per conversation. That automatic check looks for current branch cleanup, issue-scoped `.copilot-tracking/` files for merged issues, sibling worktrees, orphan branches, fail-open git conditions, and opt-in cleanup choices. Persistent calibration data is excluded from cleanup detection. Current-worktree cleanup commands are narrative inline text only and must be run from another checkout; sibling and orphan cleanup commands appear inside the fenced block. If cleanup is needed, it prompts you before running fenced cleanup commands. If `pwsh` is unavailable, the detector script is missing, or the detector returns non-JSON output, the automatic check skips silently. If session-memory access fails or candidate git checks fail, the detector fails open; explicit manual detector runs remain available after the automatic guard fires. For the full protocol, load the `session-startup` skill from `skills/session-startup/SKILL.md`.

**Requires**: PowerShell 7+ (`pwsh`) installed on PATH.

### 7. Project Scaffolding (Phase 5 of Setup Wizard)

When you run `/setup` and opt into Phase 5, the wizard can generate starter files for your project:

| File | What it does |
|------|-------------|
| `.gitignore` additions | Appends agent-orchestra tracking dirs (`/.copilot-tracking/`, `/.copilot-tracking-archive/`) and optional entries (`screenshots/`, `/.playwright-mcp/`) — additive only, never removes existing lines |
| `.vscode/settings.json` | Editor defaults: `formatOnSave`, `files.exclude`, `search.exclude`; web projects also add `workbench.browser.enableChatTools: true` for VS Code 1.110+ native browser tools |
| `.vscode/extensions.json` | Empty recommendations array for you to populate |
| `.vscode/mcp.json` *(web projects, optional)* | Playwright MCP config — optional fallback for users who prefer it over VS Code 1.110+ native browser tools |
| `.github/instructions/browser-tools.instructions.md` *(web projects)* | Dev server startup rules and browser tool selection priority (native tools primary, Playwright MCP fallback), with your port and run command substituted |
| `Documents/` structure | Creates `Design/`, `Decisions/`, `Development/` subdirectories |

If any file already exists, Phase 5 asks before overwriting (`.vscode/settings.json`, `.vscode/mcp.json`) or skips silently (`.vscode/extensions.json`). `.gitignore` additions are always additive — no existing lines are removed.

## Commit Policy

By default, Code-Conductor auto-commits after each validated plan step. Each commit represents a state that has passed the validation ladder (Tier 1) and RC conformance gate — no untested code is committed.

### Opting Out

To disable per-step auto-commits, add this section to your project's `.github/copilot-instructions.md`:

```markdown
## Commit Policy

auto-commit: disabled
```

The value is case-insensitive (`disabled`, `Disabled`, and `DISABLED` are all recognized).

When opted out:

- The validation ladder and RC conformance gate still run at every step (unchanged)
- Progress checkpoints (`— ✅ DONE`) still update in session memory (unchanged)
- Code-Conductor will prompt you to commit manually when needed (e.g., before post-fix review diff scoping)
- The formatting gate in Step 4 (PR creation) may still auto-commit formatting fixes — this is independent of per-step commits and runs unconditionally

### Squash-on-Merge Recommendation

Whether auto-commits are enabled or disabled, squash-on-merge is recommended for feature branches. The per-step commits are valuable during review for understanding logical boundaries, but the main branch benefits from clean single-commit-per-feature history.

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

1. **Plugin installed + working in a cloned repo** — the plugin loads agents from GitHub; the workspace `.github/agents/` folder loads them again. Fix: uninstall the plugin, or close the agent-orchestra folder from your VS Code workspace (not recommended — prefer uninstalling the plugin if you want the clone experience).
2. **Plugin installed + `chat.agentFilesLocations` in settings** — two sources, two copies of every agent. Fix: remove `chat.agentFilesLocations` from your VS Code user settings (keep `chat.agentSkillsLocations`, `chat.instructionsFilesLocations`, and `chat.promptFilesLocations` — those are safe).
3. **Global `chat.agentFilesLocations` + working in a repo with `.github/agents/`** — global path and workspace auto-discovery both find the agents. Fix: remove `chat.agentFilesLocations` from user settings if you only need agents in the agent-orchestra clone.

> **Quick fix checklist**: Open VS Code user `settings.json` (`Ctrl+,` → open `settings.json`) and check for `chat.agentFilesLocations` and `chat.plugins.marketplaces`. Having entries for both plugin and clone-path settings is the most common cause of duplicates.
