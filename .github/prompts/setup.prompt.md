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
> - Run `/setup` in your **target project workspace** (the repo you want to configure) — not inside the workflow-template repo itself.
> - If your workspace is brand-new and completely empty, create at least one file first (e.g., a `README.md`) before running `/setup`. VS Code's workspace context provider will crash on a zero-file workspace.
> - **Recommended model**: Claude Opus — this wizard benefits from deep reasoning for architecture and tech stack decisions.

## Phase 0 — Prerequisites Check (automatic)

Before running version checks, perform these two workspace pre-flight checks:

**Pre-flight check 0 — Working directory display**

Display the current working directory (using `Get-Location` or `pwd`) and confirm: "You are running `/setup` in: **{cwd}**. Is this your intended target repository? (yes / provide correct path)" If the user provides a different path, `cd` to that path before continuing to checks 1 and 2.

**Pre-flight check 1 — Empty workspace**

List the user-visible (non-hidden) files in the workspace root, excluding `.git/`. If no such files exist:

- Create a `README.md` file with placeholder content (e.g., `# Project`).
- Inform the user: "Your workspace was empty — I've created a `README.md` placeholder so VS Code's context provider can function. You can update this file with your project name after setup."
- Continue to the version checks below.

**Pre-flight check 2 — Wrong workspace**

Check whether `.github/agents/` exists and contains 10 or more `.agent.md` files. If it does:

- Warn: "⚠️ This workspace looks like the workflow-template repo itself, not a target project. `/setup` should be run in the repo you want to configure, not in the template."
- Ask: "Would you like to continue anyway (e.g., you're intentionally reconfiguring this repo), or stop here?"
- If the user chooses to stop: end the wizard.
- If the user chooses to continue: proceed with version checks.

Run the following checks automatically before asking any questions. Report all results clearly, warn on anything missing or outdated, then continue to Phase 1.

| Check             | Command                      | Minimum                                    |
| ----------------- | ---------------------------- | ------------------------------------------ |
| VS Code version   | `code --version`             | 1.109.3                                    |
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

> **Skip gate**: Run `echo $env:WORKFLOW_TEMPLATE_ROOT` (Windows) or `echo $WORKFLOW_TEMPLATE_ROOT` (macOS/Linux) in a terminal and report the result.
>
> - If it prints a valid path to an existing directory → ask: "WORKFLOW_TEMPLATE_ROOT is already set to `<path>`. Skip Phase 1?" If yes, skip to Phase 2.
> - If it prints a path but the directory no longer exists → inform the user the path is stale and offer to update it.
> - If it is empty or not set → continue with Phase 1 below.

If not configured, ask:

1. **Absolute path to your workflow-template clone** — the folder where you cloned this repository (e.g., `C:\Users\you\workflow-template` or `/Users/you/workflow-template`)
2. **Your OS** — Windows, macOS, or Linux

Once you have those answers:

**Step 1.1** — Show the exact command to set `WORKFLOW_TEMPLATE_ROOT` permanently:

For **Windows** (recommended — persists across all sessions):

```powershell
[System.Environment]::SetEnvironmentVariable('WORKFLOW_TEMPLATE_ROOT', 'C:\path\to\workflow-template', 'User')
```

For **Windows** (PowerShell profile — session-scope only, not recommended for VS Code GUI launch):

```powershell
# Add to $PROFILE:
$env:WORKFLOW_TEMPLATE_ROOT = "C:\path\to\workflow-template"
```

For **macOS/Linux**:

```bash
# Add to ~/.zshrc or ~/.bashrc:
export WORKFLOW_TEMPLATE_ROOT="/path/to/workflow-template"
```

> **Important**: VS Code launched from the Start Menu or a desktop shortcut may not run your PowerShell profile. Use the permanent approach if the hook displays a "not set" error.

**Step 1.2** — Show the VS Code settings to add to your user `settings.json` (`Ctrl+,` → open `settings.json`):

```json
{
  "chat.hookFilesLocations": ["<your-path>/workflow-template/.github/hooks"],
  "chat.agentFilesLocations": ["<your-path>/workflow-template/.github/agents"],
  "chat.agentSkillsLocations": ["<your-path>/workflow-template/.github/skills"],
  "chat.instructionsFilesLocations": {
    "<your-path>/workflow-template/.github/instructions": true
  },
  "chat.promptFilesLocations": {
    "<your-path>/workflow-template/.github/prompts": true
  }
}
```

Replace `<your-path>` with the absolute path from Step 1.1.

| Setting                           | What it enables                                                   |
| --------------------------------- | ----------------------------------------------------------------- |
| `chat.hookFilesLocations`         | Session cleanup hook (detects stale branches after PR merge)      |
| `chat.agentFilesLocations`        | All workflow agents available in every repository                 |
| `chat.agentSkillsLocations`       | All workflow skills available in every repository                 |
| `chat.instructionsFilesLocations` | Shared instruction files apply across all your repositories       |
| `chat.promptFilesLocations`       | Shared prompt files (e.g. `/setup`) available in every repository |

> **Windows path format**: Use forward slashes or escaped backslashes: `"C:/Users/you/workflow-template/.github/hooks"` or `"C:\\Users\\you\\workflow-template\\.github\\hooks"`.

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

   > _Not sure?_ If the user indicates uncertainty, ask 2–3 clarifying questions about their project (e.g., team experience, deployment target, performance needs). Then use the project description from question 2 to generate 2–3 language recommendations with reasoning and pros/cons. Use `ask_questions` for the user to select. Experienced users who answer directly skip this step.

4. **Framework + version** — (e.g., Express 4.x, Spring Boot 3.2, FastAPI 0.110, none) _(or say "not sure" for help choosing)_

   > _Not sure?_ If the user indicates uncertainty, generate 2–3 framework recommendations based on the language chosen in question 3 and the project description from question 2. Include reasoning and pros/cons. Use `ask_questions` for selection.

5. **Database** — (e.g., PostgreSQL 15, MongoDB 7, SQLite, none) _(or say "not sure" for help choosing)_
   > _Not sure?_ If the user indicates uncertainty, generate 2–3 database recommendations based on the project type, scale, and stack from prior answers. Include reasoning and pros/cons. Use `ask_questions` for selection.

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

- If it does not exist → create it with the workflow-template lines below plus a comment.
- If it exists → read the current contents. Append ONLY the lines that are not already present. Do not add duplicates.

Lines to ensure are present:

```
# Copilot workflow-template tracking (agent scaffolding — local only)
/.copilot-tracking/
/.copilot-tracking-archive/

# Visual verification screenshots (local only)
screenshots/

# Playwright MCP working directory
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

**5d. Web project extras (conditional)**

Ask: "Is this a web project with a browser-based dev server?" Options: (a) Yes, (b) No.

If yes:

- Ask: "What port does your dev server run on?" (default: infer from run command in Phase 4, or suggest 3000)
- Check whether `.vscode/mcp.json` already exists. If it exists, ask: "`.vscode/mcp.json` already exists. Overwrite with Playwright MCP defaults, or skip?" If skip → skip 5d entirely.
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

- Generate `.github/instructions/browser-mcp.instructions.md` with the user's actual port and run command substituted:

```markdown
# Browser MCP Instructions

## Port convention

- Dev server runs on `localhost:{PORT}` ({FRAMEWORK} default).
- Start all MCP navigation from `http://localhost:{PORT}` unless a task explicitly requires another URL.

## Dev server startup check (port {PORT})

1. Check whether `localhost:{PORT}` is already healthy.
2. If not healthy, run `{RUN_COMMAND}` to start the dev server.
3. Poll health until ready or timeout at 30 seconds.
4. If timeout is reached, stop and report startup failure.

## Error handling

- If port `{PORT}` is in use by a non-dev-server process, report it and stop.
- If startup times out, report the timeout and do not continue browser actions.
- If the MCP browser crashes, relaunch once and retry the current step once.
- MCP is configured with `--block-service-workers` in `.vscode/mcp.json`; keep it enabled.

## Screenshots

- Save transient screenshots to `screenshots/`.
- Do not treat `screenshots/` as a durable artifact folder.

## Cleanup

- Close browser sessions created for MCP work when done.
- Stop any dev server process started by the agent if the task no longer needs it.
- Avoid leaving orphaned browser or server processes.
```

Replace `{PORT}` with the user's dev server port, `{FRAMEWORK}` with the framework name from Phase 2, and `{RUN_COMMAND}` with the run command from Phase 4.

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
You're ready to use agents. Try: `@Issue-Designer`, `@Issue-Planner`, or `@Code-Conductor`.
```
