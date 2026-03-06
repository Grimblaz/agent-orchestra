# Setup Project

Configure a target project for both GitHub Copilot agents and Claude Code.

## Usage

`/project:setup`

Run this in a target project (not in the workflow-template repo itself) to generate configuration files.

## Prerequisites

Verify these are available:
- `git` — version control
- `gh` — GitHub CLI (optional but recommended)

Check what already exists:
- `.github/copilot-instructions.md` — skip Copilot config if present
- `CLAUDE.md` — skip Claude Code config if present
- `.github/architecture-rules.md` — skip architecture rules if present

## Phase 1: Project Basics

Ask the user for:
1. **Project name** — what is this project called?
2. **Overview** — what does it do? (1-2 sentences)
3. **Language + version** — e.g., TypeScript 5.x, Java 21, Python 3.12
4. **Framework + version** — e.g., Express 4.x, Spring Boot 3.2.x, FastAPI 0.110
5. **Database** — e.g., PostgreSQL 15, MongoDB, none

## Phase 2: Architecture & Conventions

Ask the user for:
6. **Architecture style** — e.g., layered, hexagonal, CQRS, monolith, microservice
7. **Key conventions** — naming rules, DI approach, error handling patterns
8. **Build tool** — e.g., npm, Gradle, Poetry, Cargo

## Phase 3: Commands

Ask the user for:
9. **Build command** — e.g., `npm run build`, `./gradlew build`
10. **Test command** — e.g., `npm test`, `./gradlew test`, `poetry run pytest`
11. **Lint/typecheck command** — e.g., `npm run lint`, `poetry run ruff check .`
12. **Quick-validate command** — fast check to run before PRs

## Phase 4: Generate Files

Generate the following files using the collected answers:

### `.github/copilot-instructions.md`
Follow the format in the workflow-template's `examples/` directory. Include: Project name, Overview, Technology Stack, Architecture diagram, Directory Structure, Key Conventions, Build & Run commands, Quick-Validate command.

### `CLAUDE.md`
Follow the same structure but adapted for Claude Code:
- Same project overview, tech stack, architecture, conventions, and commands
- Add the **Workflow for Claude Code** section (plan → implement → test → refactor → review → document → PR) with role guide references to `.github/agents/` files
- Add the **Skills Reference** table pointing to `.github/skills/` files
- Add the **Shared Instructions** list pointing to `.github/instructions/` files

### `.github/architecture-rules.md`
Layer structure, dependency rules, testing rules per layer, naming conventions.

## Phase 5: Scaffolding (Optional)

Ask if the user wants project scaffolding:

- `.gitignore` additions — append `.copilot-tracking/` and `.copilot-tracking-archive/` (additive only)
- `.vscode/settings.json` — editor defaults
- `Documents/` directory structure — `Design/`, `Decisions/`, `Development/`

## Completion

After generating files, display a summary of what was created and next steps:
- Point to `CUSTOMIZATION.md` in the workflow-template for advanced configuration
- Suggest running `/project:start-issue {number}` to begin work on an issue
