# Customization Guide

This guide explains how to configure the workflow template for your project.

## Quick Option: Setup Wizard

Open GitHub Copilot Chat, run the **`/setup`** command, and answer the questions. Copilot will generate your config files automatically.

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

The workflow-template includes a `SessionStart` hook that detects stale feature branches and leftover tracking files after a PR is merged, and prompts you to run cleanup at the start of your next VS Code Copilot session.

**Setup — two steps:**

**Step 1**: Add to your user or workspace VS Code settings:

```json
"chat.hookFilesLocations": ["/absolute/path/to/workflow-template/.github/hooks"]
```

> **Windows path**: Use forward slashes or escaped backslashes in the JSON value, e.g. `"C:/Users/you/workflow-template/.github/hooks"` or `"C:\\Users\\you\\workflow-template\\.github\\hooks"`.

**Step 2**: Set the `WORKFLOW_TEMPLATE_ROOT` environment variable to the absolute path of your local workflow-template clone. Without this, the hook will display an error message instead of running.

**Windows (permanent — recommended)**:

Set via System Properties > Advanced > Environment Variables, or from an elevated PowerShell session:

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

## Troubleshooting

**Agents not following instructions?**

- Verify `.github/copilot-instructions.md` exists and has real project content
- Check agent files have valid YAML frontmatter with `---` delimiters

**Skills not being used?**

- Confirm `SKILL.md` has `name` and `description` frontmatter
- Enable `chat.useAgentSkills` in VS Code settings (requires VS Code 1.108+)
