---
agent: agent
description: "Interactive setup wizard — 6 phases. Phase 0 checks prerequisites, Phase 1 configures your machine (one-time), Phases 2–4 configure this repo, Phase 5 generates project scaffolding. Skip any phase you've already completed."
---

# Project Setup Wizard

Setup has six phases. Each phase includes a skip gate so you can jump to exactly what you need.
**Phase 0** always runs automatically (prerequisites check — no input required).
**Phases 1–5** each ask whether to skip before showing questions.

---

> **Before you start**
>
> - Run `/setup` in your **target project workspace** (the repo you want to configure) — not inside the copilot-orchestra repo itself.
> - If your workspace is brand-new and completely empty, don't worry — Phase 0 will automatically create a `README.md` placeholder. (VS Code's workspace context provider crashes on zero-file workspaces; Phase 0 handles this.)
> - **Recommended model**: Claude Opus — this wizard benefits from deep reasoning for architecture and tech stack decisions. _(o3 or GPT-4o also work well if Opus is unavailable.)_

## Phase 0 — Prerequisites Check (automatic)

Before running version checks, perform these three workspace pre-flight checks:

**Pre-flight check 0 — Working directory display**

Display the current working directory (using `Get-Location` or `pwd`) and confirm: "You are running `/setup` in: **{cwd}**. Is this your intended target repository? (yes / provide correct path)" If the user provides a different path, `cd` to that path before continuing to checks 1 and 2.

**Pre-flight check 1 — Empty workspace**

List the user-visible (non-hidden) files in the workspace root, excluding `.git/`. If no such files exist:

- Create a `README.md` file with placeholder content (e.g., `# Project`).
- Inform the user: "Your workspace was empty — I've created a `README.md` placeholder so VS Code's context provider can function. You can update this file with your project name after setup."
- Continue to the version checks below.

**Pre-flight check 2 — Wrong workspace**

Check whether `.github/agents/` exists and contains 10 or more `.agent.md` files. If it does:

- Warn: "⚠️ This workspace looks like the copilot-orchestra repo itself, not a target project. `/setup` should be run in the repo you want to configure, not in the template."
- Ask: "Would you like to continue anyway (e.g., you're intentionally reconfiguring this repo), or stop here?"
- If the user chooses to stop: end the wizard.
- If the user chooses to continue: proceed with version checks.

Run the following checks automatically before asking any questions. Report all results clearly, warn on anything missing or outdated, then continue to Phase 1.

| Check             | Command                      | Minimum                                    |
| ----------------- | ---------------------------- | ------------------------------------------ |
| VS Code version   | `code --version`             | 1.107                                      |
| PowerShell (pwsh) | `pwsh --version` in terminal | 7.0+                                       |
| Git               | `git --version` in terminal  | any recent version                         |
| GitHub CLI (gh)   | `gh --version` in terminal   | optional, recommended for issue operations |

**Reporting format**:

- ✅ — installed and meets minimum
- ⚠️ — installed but below minimum (include the version found and what's required)
- ❌ — not found on PATH (include install link)

After reporting:

- **If VS Code is not found or is below the minimum version**: stop here and ask the user to install or update VS Code before continuing — agents cannot function without it.
- **For all other prerequisites** below minimum or not found: continue to Phase 1. These are warnings only.

---

## Phase 1 — User Setup (one-time, machine-level)

### Plugin Overlap Check

Before proceeding, check whether the user has the copilot-orchestra (or legacy workflow-template) plugin already installed. This prevents accidentally creating duplicate agents by combining plugin distribution with clone-path settings.

**Step**: Run the command for the user's OS (determined by context from the cwd shown in Phase 0 or the path separator the user provides — Windows paths start with a drive letter):

- **Windows**: `Select-String -Path "$env:APPDATA\Code\User\settings.json" -Pattern "Grimblaz/(workflow-template|copilot-orchestra)" -Quiet 2>$null`
- **macOS**: `grep -qE "Grimblaz/(workflow-template|copilot-orchestra)" "$HOME/Library/Application Support/Code/User/settings.json" 2>/dev/null && echo True`
- **Linux**: `grep -qE "Grimblaz/(workflow-template|copilot-orchestra)" "$HOME/.config/Code/User/settings.json" 2>/dev/null && echo True`

> **Important**: Use string search (`Select-String` on Windows, `grep` on macOS/Linux), NOT `ConvertFrom-Json` — VS Code `settings.json` is JSONC (allows comments) and `ConvertFrom-Json` will fail on files with comments.

**If the settings file does not exist or the command fails**: continue silently to the skip gate below — no warning needed.

> **Scope note**: This check only covers the standard VS Code stable installation path (`Code`). VS Code Insiders (`Code - Insiders`) and VSCodium users are not detected — if you know you use Insiders or VSCodium, treat this as `True` if the plugin is installed. In Dev Container and Remote-SSH contexts, the host `settings.json` is not accessible from the container filesystem; the check will always fail silently and skip — this is expected.

**If the command returns `True`** (the copilot-orchestra or workflow-template marketplace entry is present in your VS Code settings): inform the user:

> "It looks like you have the copilot-orchestra plugin installed (found in your VS Code settings). Adding `chat.agentFilesLocations` at the same time will cause duplicate agents to appear in the chat picker.
>
> **Option 1 — Keep plugin, skip agent settings (recommended if you just want to use the workflow)**:
> Continue Phase 1, but in Step 1.2 only add `chat.instructionsFilesLocations` and `chat.promptFilesLocations`. Skip `chat.agentFilesLocations` (the plugin already provides that). If `chat.agentFilesLocations` is already present in your `settings.json` from a previous setup, **remove it now** — it conflicts with the plugin and will cause duplicates regardless of which settings you add next.
>
> **Option 2 — Uninstall plugin, use full clone settings (use this if you want to customize agents or add project-specific instructions)**:
> Continue with all four settings. First uninstall the plugin from the Extensions view (`Ctrl+Shift+X`, search `@agentPlugins copilot-orchestra` (or `workflow-template` if using the legacy name), uninstall). This gives you local editable copies of all agents and skills.
>
> Which option do you prefer?"
>
> Wait for the user's choice before continuing to the skip gate.

**If the command returns no output** (plugin not installed): continue normally to the skip gate below.

> **Skip gate**: Run `echo $env:COPILOT_ORCHESTRA_ROOT` (Windows) or `echo $COPILOT_ORCHESTRA_ROOT` (macOS/Linux) in a terminal. If empty, also check `echo $env:WORKFLOW_TEMPLATE_ROOT` / `echo $WORKFLOW_TEMPLATE_ROOT` as a fallback.
>
> - If either prints a valid path to an existing directory → ask: "Root path is already configured (`<path>`). Skip Phase 1?" If yes, skip to Phase 2.
> - If it prints a path but the directory no longer exists → inform the user the path is stale and offer to update it.
> - If it is empty or not set → continue with Phase 1 below.

If not configured, ask:

1. **Absolute path to your copilot-orchestra clone** — the folder where you cloned this repository (e.g., `C:\Users\you\copilot-orchestra` or `/Users/you/copilot-orchestra`)
2. **Your OS** — Windows, macOS, or Linux

Once you have those answers:

**Step 1.1** — Show the exact command to set `COPILOT_ORCHESTRA_ROOT` permanently:

For **Windows** (recommended — persists across all sessions):

```powershell
[System.Environment]::SetEnvironmentVariable('COPILOT_ORCHESTRA_ROOT', 'C:\path\to\copilot-orchestra', 'User')
```

For **Windows** (PowerShell profile — session-scope only, not recommended for VS Code GUI launch):

```powershell
# Add to $PROFILE:
$env:COPILOT_ORCHESTRA_ROOT = "C:\path\to\copilot-orchestra"
```

For **macOS/Linux**:

```bash
# Add to ~/.zshrc or ~/.bashrc:
export COPILOT_ORCHESTRA_ROOT="/path/to/copilot-orchestra"
```

> **Important**: VS Code launched from the Start Menu or a desktop shortcut may not run your PowerShell profile. Use the permanent approach to ensure `COPILOT_ORCHESTRA_ROOT` is always available — the Session Startup Check (in `.github/copilot-instructions.md`) silently skips if neither `COPILOT_ORCHESTRA_ROOT` nor `WORKFLOW_TEMPLATE_ROOT` is set.

**Step 1.2** — Show the VS Code settings to add to your user `settings.json` (`Ctrl+,` → open `settings.json`):

```json
{
  "chat.agentFilesLocations": ["<your-path>/copilot-orchestra/.github/agents"],
  "chat.agentSkillsLocations": ["<your-path>/copilot-orchestra/.github/skills"],
  "chat.instructionsFilesLocations": {
    "<your-path>/copilot-orchestra/.github/instructions": true
  },
  "chat.promptFilesLocations": {
    "<your-path>/copilot-orchestra/.github/prompts": true
  }
}
```

Replace `<your-path>` with the absolute path from Step 1.1.

| Setting                           | What it enables                                                   |
| --------------------------------- | ----------------------------------------------------------------- |
| `chat.agentFilesLocations`        | All workflow agents available in every repository                 |
| `chat.agentSkillsLocations`       | All workflow skills available in every repository                 |
| `chat.instructionsFilesLocations` | Shared instruction files apply across all your repositories       |
| `chat.promptFilesLocations`       | Shared prompt files (e.g. `/setup`) available in every repository |

> **Windows path format**: Use forward slashes or escaped backslashes: `"C:/Users/you/copilot-orchestra/.github/instructions"` or `"C:\\Users\\you\\copilot-orchestra\\.github\\instructions"`.

**Step 1.3** — Confirm: "Have you applied the command and settings above?" Wait for confirmation before continuing to Phase 2.

---

**Working directory check**: Before Phase 2, display the current working directory (using `Get-Location` or `pwd`) and confirm: "About to configure the project at: **{cwd}**. Is this your intended target repository? (yes / provide correct path)" If the user provides a different path, change directory to that path before continuing.

## Phase 2 — Project Basics

> **Skip gate**: Check whether `.github/copilot-instructions.md` exists in the current workspace.
>
> - If it exists → ask: "`.github/copilot-instructions.md` already exists. What would you like to do?" Options: (a) Skip Phase 2 (keep existing file), (b) Regenerate it (answer questions and overwrite). If skip, jump to Phase 3.
> - If it does not exist → continue with Phase 2 questions below.

Answer these questions about the project:

1. **Project name** — What is this project called? (e.g., "Order Service")
2. **What does it do?** — 1–2 sentences describing the purpose. (e.g., "REST API that manages customer orders for an e-commerce platform.")
3. **Primary language + version** — (e.g., TypeScript 5.x, Java 21, Python 3.12) _(or say "not sure" for help choosing)_

   > _Not sure?_ If the user indicates uncertainty, ask 2–3 clarifying questions about their project (e.g., team experience, deployment target, performance needs). Then use the project description from question 2 to generate 2–3 language recommendations with reasoning and pros/cons. Use `vscode/askQuestions` for the user to select. Experienced users who answer directly skip this step.

4. **Framework + version** — (e.g., Express 4.x, Spring Boot 3.2, FastAPI 0.110, none) _(or say "not sure" for help choosing)_

   > _Not sure?_ If the user indicates uncertainty, generate 2–3 framework recommendations based on the language chosen in question 3 and the project description from question 2. Include reasoning and pros/cons. Use `vscode/askQuestions` for selection.

5. **Database** — (e.g., PostgreSQL 15, MongoDB 7, SQLite, none) _(or say "not sure" for help choosing)_
   > _Not sure?_ If the user indicates uncertainty, generate 2–3 database recommendations based on the project type, scale, and stack from prior answers. Include reasoning and pros/cons. Use `vscode/askQuestions` for selection.

Once all Phase 2 questions have been answered (including any "Not sure?" branches), proceed to Phase 3.

---

## Phase 3 — Architecture & Conventions

> **Skip gate**: Check whether `.github/architecture-rules.md` exists in the current workspace.
>
> - If it exists → ask: "`.github/architecture-rules.md` already exists. What would you like to do?" Options: (a) Skip Phase 3 (keep existing file), (b) Regenerate it (answer questions and overwrite). If skip, jump to Phase 4.
> - If it does not exist → continue with Phase 3 questions below.

6. **Architecture style** — (e.g., layered MVC, hexagonal, microservices, monolith, feature-based)
7. **Key conventions** — Any naming rules, patterns, or standards? (e.g., "Use constructor injection; all public functions need JSDoc; errors use ApiError class")
8. **Build tool** — (e.g., npm / tsc, Gradle 8, Poetry, Maven)

Collect all answers before proceeding to Phase 4.

---

## Phase 4 — Commands

> **Skip gate**: If Phase 2 was skipped AND Phase 3 was skipped AND Phase 5 will be skipped (ask: "Will you skip Phase 5 scaffolding?"), offer to skip Phase 4: "Since no config files will be generated, you can skip Phase 4 command questions. Enter 'skip' to continue, or press Enter to answer them now." If skipped, note Phase 4 as skipped in the Setup Summary.

9. **Build command** — How do you build? (e.g., `npm run build`)
10. **Run command** — How do you start the dev server or application? (e.g., `npm run dev`, `./gradlew bootRun`)
11. **Test command** — How do you run tests? (e.g., `npm test`, `pytest`)
12. **Lint/type-check command** — (e.g., `npm run lint && npm run typecheck`, `./gradlew check`)
13. **Quick-validate command** — Fastest check before a PR (usually build + lint combined). (e.g., `npm run build && npm run lint`)

---

## Phase 5 — Project Scaffolding

> **Skip gate**: Ask: "Would you like me to generate project scaffolding files (`.gitignore` additions, `.vscode/` defaults, `Documents/` structure)?" Options: (a) Yes — generate scaffolding, (b) Skip — I'll manage these files myself. If skip, jump to Generation.

If generating scaffolding:

**5a. `.gitignore` additions**

Check whether `.gitignore` exists in the workspace root.

- If it does not exist → create it with the Copilot Orchestra entries below plus a comment.
- If it exists → read the current contents. Append ONLY the lines that are not already present. Do not add duplicates.

Lines to ensure are present:

```
# Copilot Orchestra tracking (agent scaffolding — local only)
/.copilot-tracking/
/.copilot-tracking-archive/

# Visual verification screenshots (local only)
screenshots/

# Playwright MCP working directory (fallback — native browser tools don't need this)
/.playwright-mcp/

# Loose PNGs in project root (e.g. CE-gate screenshots)
/*.png

# Pester test output
testResults.xml
```

**5b. `.vscode/settings.json`**

Check whether `.vscode/settings.json` exists.

- If it does not exist → create it with these defaults.
- If it exists → ask: "`.vscode/settings.json` already exists. Overwrite with defaults, or skip?" If skip, move on.

Content to generate:

```json
{
  "editor.formatOnSave": true,
  "files.exclude": {
    "**/.git": true,
    "**/node_modules": true,
    "**/dist": true,
    "**/coverage": true
  },
  "search.exclude": {
    "**/node_modules": true,
    "**/dist": true,
    "**/coverage": true,
    "**/package-lock.json": true
  }
}
```

**5c. `.vscode/extensions.json`**

Check whether `.vscode/extensions.json` exists.

- If it does not exist → create it with an empty recommendations array (user can populate per their stack).
- If it exists → skip.

Content to generate:

```json
{
  "recommendations": []
}
```

**5d. Web project browser tools configuration (conditional)**

Ask: "Is this a web project with a browser-based dev server?" Options: (a) Yes, (b) No.

If yes:

- Ask: "What port does your dev server run on?" (default: infer from run command in Phase 4, or suggest 3000)
- Add `"workbench.browser.enableChatTools": true` to `.vscode/settings.json` (merge into existing file if present, or note that this key must be added). This enables VS Code 1.110+ native browser tools — zero MCP setup required.
- Generate `.github/instructions/browser-tools.instructions.md` with the user's actual port, framework name, and run command substituted:

```markdown
# Browser Tools Instructions

## Port convention

- Dev server runs on `localhost:{PORT}` ({FRAMEWORK} default).
- Start all browser navigation from `http://localhost:{PORT}` unless a task explicitly requires another URL.

## Dev server startup check (port {PORT})

1. Check whether `localhost:{PORT}` is already healthy.
2. If not healthy, run `{RUN_COMMAND}` to start the dev server.
3. Poll health until ready or timeout at 30 seconds.
4. If timeout is reached, stop and report startup failure.

## Browser tool selection

Use tools in this priority order:

1. **VS Code native browser tools** (`openBrowserPage`, `screenshotPage`, `clickElement`, `typeInPage`, `readPage`, etc.) — enabled via `workbench.browser.enableChatTools: true` in `.vscode/settings.json`; zero setup
2. **Playwright MCP** (`playwright/*` tools) — if `.vscode/mcp.json` is configured; requires VS Code restart after adding
3. **Manual fallback** — request user-pasted screenshots

## Error handling

- If port `{PORT}` is in use by a non-dev-server process, report it and stop.
- If startup times out, report the timeout and do not continue browser actions.
- If native browser tools fail, try Playwright MCP; if still failing, use manual screenshot paste fallback.

## Screenshots

- Save transient screenshots to `screenshots/`.
- Do not treat `screenshots/` as a durable artifact folder.

## Cleanup

- Close browser sessions when done.
- Stop any dev server process started by the agent if the task no longer needs it.
- Avoid leaving orphaned browser or server processes.

## Canvas interaction

`clickElement` is selector-based only — it has **no coordinate or position parameter**. It cannot target objects rendered inside a `<canvas>` element.

For canvas games (Phaser 3, WebGL, etc.), use `runPlaywrightCode` with `page.mouse.click(cssX, cssY)`:

- Convert game-space coordinates to CSS page coordinates via `getBoundingClientRect()`
- Load `.github/skills/browser-canvas-testing/SKILL.md` for the full formula and worked example
```

Replace `{PORT}` with the user's dev server port, `{FRAMEWORK}` with the framework name from Phase 2, and `{RUN_COMMAND}` with the run command from Phase 4.

- Ask: "Also configure Playwright MCP as a fallback? (needed only if you prefer it over native browser tools, or require capabilities not yet in VS Code built-in tools)" Options: (a) Yes, (b) No (recommended: No — native tools are sufficient for most projects).

  If yes (Playwright MCP fallback):
  - Check whether `.vscode/mcp.json` already exists. If it exists, ask: "`.vscode/mcp.json` already exists. Overwrite with Playwright MCP defaults, or skip?" If skip → skip Playwright MCP config.
  - Generate `.vscode/mcp.json`:

```json
{
  "servers": {
    "playwright": {
      "type": "stdio",
      "command": "npx",
      "args": ["@playwright/mcp", "--block-service-workers"]
    }
  }
}
```

- Inform the user: "Playwright MCP also requires uncommenting `# - \"playwright/*\"` in the `tools:` list in the frontmatter of each agent used for browser workflows (e.g. `UI-Iterator.agent.md`, `Code-Conductor.agent.md`). Without this step, agents cannot invoke `playwright/*` tools even with `.vscode/mcp.json` configured."

**5e. `Documents/` directory structure**

Check whether `Documents/Design/`, `Documents/Decisions/`, and `Documents/Development/` exist. Create any that are missing, adding a `.gitkeep` file in each.

---

## Generation

Once all phases are complete (or skipped), generate the config files:

**If Phase 2 was completed or regenerated** → Generate `.github/copilot-instructions.md`:

Use the answers from Phases 2, 3, and 4 to fill in:

- Project name and overview (Phase 2 answers 1–2)
- Technology stack (Phase 2 answers 3–5 + Phase 3 answer 8)
- Architecture description (Phase 3 answers 6–7)
- Build, run, and test commands (Phase 4 answers 9–13)

Follow the format in `examples/nodejs-typescript/copilot-instructions.md` (or the appropriate stack example). Include all standard sections: Overview, Technology Stack, Architecture, Key Conventions, Build & Run, Quick-Validate.

> **If Phase 3 was skipped**: Omit the Architecture section from the generated `copilot-instructions.md` and add a comment: `# Architecture: see .github/architecture-rules.md`. Do not hallucinate architecture details — leave those details to the existing rules file.

**If Phase 3 was completed or regenerated** → Generate `.github/architecture-rules.md`:

Use Phase 3 answers to fill in layer structure, dependency rules, testing rules, and naming conventions. Follow the format in `examples/nodejs-typescript/architecture-rules.md` (or the appropriate stack example). Include all standard sections: Layer Architecture, Dependency Rules, Testing Rules, File & Naming Conventions.

**If pre-existing files were present and user chose to regenerate** → Overwrite the existing file with the new content.

**If pre-existing files were present and user chose to skip** → Do not overwrite. Confirm that the existing file was preserved.

> **Alternative for conflicts**: If the user is unsure about overwriting, offer to create `.github/copilot-instructions.new.md` as a draft for manual comparison and merging.

> **Reference**: See `examples/` for three complete filled-in examples showing format and depth: `examples/spring-boot-microservice/` (Java), `examples/nodejs-typescript/` (TypeScript), `examples/python/` (Python).

**If Phase 0 auto-created a `README.md` placeholder** → Update that file's heading from `# Project` to `# {project name from Phase 2 Q1}`.

---

## Setup Summary

After all phases and generation, print a summary:

```
## Setup Summary

### Phase 0 — Prerequisites
✅ VS Code: [version]
✅/⚠️/❌ pwsh: [version or status]
✅/⚠️/❌ git: [version or status]
✅/⚠️/❌ gh: [version or status]

### Phase 1 — User Setup
[Completed / Skipped]

### Phase 2 — Project Basics
[Completed / Skipped — existing file preserved]

### Phase 3 — Architecture & Conventions
[Completed / Skipped — existing file preserved]

### Phase 4 — Commands
[Completed]

### Phase 5 — Scaffolding
[Completed / Skipped]
Files generated: [list each file created or "none"]
Files skipped: [list each file that already existed and was skipped]

### Generated Config Files
[List: copilot-instructions.md, architecture-rules.md — created / updated / skipped]

---
You're ready to use agents. Try: `@Experience-Owner`, `@Solution-Designer`, `@Issue-Planner`, or `@Code-Conductor`.
```
