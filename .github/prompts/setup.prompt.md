---
agent: ask
description: "Interactive setup wizard — Stage 1 configures your machine (one-time), Stage 2 configures this repo for multi-agent workflows."
---

# Project Setup Wizard

Setup has two stages. **Stage 1** is a one-time machine configuration — skip it if you've already done it for another repo. **Stage 2** generates project-specific config files for this repository.

---

## Stage 1 — User Setup (one-time, machine-level)

First, check whether your machine is already configured:

- **VS Code version**: Open *Help > About* — confirm you are on **1.109.3 or later**. If not, update before continuing.
- **`WORKFLOW_TEMPLATE_ROOT`**: Run `echo $env:WORKFLOW_TEMPLATE_ROOT` (Windows) or `echo $WORKFLOW_TEMPLATE_ROOT` (macOS/Linux) in a terminal. If it prints a path, Stage 1 is already done — skip to Stage 2.

If not yet configured, please provide:

1. **Absolute path to your workflow-template clone** — the folder where you cloned this repository (e.g., `C:\Users\you\workflow-template` or `/Users/you/workflow-template`)
2. **Your OS** — Windows, macOS, or Linux

Once you answer those two questions I will:

1. **Show the exact command** to set `WORKFLOW_TEMPLATE_ROOT` permanently on your machine
2. **Show the VS Code settings** to add to your user `settings.json`:
   - `chat.hookFilesLocations` — enables the session cleanup hook
   - `chat.agentFilesLocations` — makes the workflow agents available in all your repositories without copying them
   - `chat.agentSkillsLocations` — makes the workflow skills available in all your repositories without copying them
   - `chat.instructionsFilesLocations` — makes the shared instruction files available across all your repositories
   ```json
   "chat.hookFilesLocations": ["<your-path>/workflow-template/.github/hooks"],
   "chat.agentFilesLocations": ["<your-path>/workflow-template/.github/agents"],
   "chat.agentSkillsLocations": ["<your-path>/workflow-template/.github/skills"],
   "chat.instructionsFilesLocations": {
     "<your-path>/workflow-template/.github/instructions": true
   }
   ```
3. **Confirm** the steps are complete before proceeding to Stage 2

> **What this enables**: Agents, skills, and instruction files become available in every repo you work in. A `SessionStart` hook detects stale feature branches and leftover tracking files after a PR is merged, and prompts you to clean up at the start of your next VS Code session. Without `WORKFLOW_TEMPLATE_ROOT` set, the hook will display a configuration error instead of running.

---

## Stage 2 — Repo Setup (per-project)

Answer the following questions about the project you have open. You can adjust the output after.

1. **Project name** — What is this project called? (e.g., "Order Service")
2. **What does it do?** — 1–2 sentences describing the purpose. (e.g., "REST API that manages customer orders for an e-commerce platform.")
3. **Primary language + version** — (e.g., TypeScript 5.x, Java 21, Python 3.12)
4. **Framework + version** — (e.g., Express 4.x, Spring Boot 3.2, FastAPI 0.110)
5. **Database** — (e.g., PostgreSQL 15, MongoDB 7, SQLite, none)
6. **Build tool** — (e.g., npm / tsc, Gradle 8, Poetry)
7. **Test framework** — (e.g., Jest + Supertest, JUnit 5, pytest)
8. **Architecture style** — (e.g., layered MVC, hexagonal, microservices, monolith)
9. **Key conventions** — Any naming rules, patterns, or standards your project must follow? (e.g., "Use constructor injection; all public functions need JSDoc; errors use ApiError class")
10. **Build command** — How do you build? (e.g., `npm run build`)
11. **Run command** — How do you start the dev server? (e.g., `npm run dev`)
12. **Test command** — How do you run tests? (e.g., `npm test`)
13. **Lint/type-check command** — (e.g., `npm run lint && npm run typecheck`)
14. **Quick-validate command** — Fastest check before a PR (usually build + lint combined). (e.g., `npm run build && npm run lint`)

---

## What I'll do with your Stage 2 answers

Once you've provided all answers above, I will:

1. **Generate `.github/copilot-instructions.md`** — project overview, tech stack, architecture, conventions, and build commands so agents understand your codebase
2. **Generate `.github/architecture-rules.md`** — layer structure, dependency rules, testing rules, and naming conventions based on your architecture style and conventions
3. **Confirm** what was created so you can review or adjust

> **Note**: If these files already exist, I'll ask you before overwriting — you can choose to overwrite, or I'll create draft files like `.github/copilot-instructions.new.md` for you to compare and merge manually. If you're unsure about any question, give your best guess — you can always edit the files manually afterward. See `examples/` for complete filled-in references (spring-boot-microservice for Java, nodejs-typescript for TypeScript, python for Python).