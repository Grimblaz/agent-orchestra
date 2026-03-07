# Project: Task Manager API

## Overview

REST API for task management, supporting task creation, assignment, and status tracking. This is an **example** file demonstrating how to configure `CLAUDE.md` for the multi-agent workflow.

## Technology Stack

- **Language**: TypeScript 5.x (`strict: true`)
- **Framework**: Express 4.x
- **Database**: PostgreSQL 15 (via `pg` / node-postgres)
- **Build Tool**: npm / tsc
- **Testing**: Jest + Supertest

## Architecture

Layered architecture with strict top-down dependency flow:

```text
Routes → Controllers → Services → Repositories
```

## Directory Structure

```text
src/
├── routes/              # Express routers (task.routes.ts)
├── controllers/         # Request/response handlers (TaskController.ts)
├── services/            # Business logic (TaskService.ts)
├── repositories/        # DB queries via pg (TaskRepository.ts)
├── models/              # TypeScript interfaces/types (task.model.ts)
├── dtos/                # Request/response shapes (task.dto.ts)
├── errors/              # AppError and subclasses
├── middleware/          # Auth, validation, error handler
├── config/              # Database pool, env config
└── app.ts               # Express app factory (no listen())
index.ts                 # Server entry point (listen())
```

## Key Conventions

- Compile with `strict: true` — no `any` type
- Explicit return types on all exported functions
- Constructor injection via plain TypeScript classes (graph in `src/config/container.ts`)
- Throw `AppError` for domain errors; global error middleware converts to JSON
- REST conventions with `{ data, meta }` envelope for collections
- Tests co-located as `*.test.ts` next to the file under test

## Build & Run

```bash
npm install        # Install dependencies
npm run build      # Build
npm run dev        # Run development server
npm test           # Run tests
npm run lint && npm run typecheck  # Lint / type-check
```

## Quick-Validate

```bash
npm run build && npm run lint
```

## Workflow for Claude Code

Follow the phased workflow. Each phase references a role guide in the workflow-template:

1. **Plan** — `.github/agents/Issue-Planner.agent.md`
2. **Implement** — `.github/agents/Code-Smith.agent.md`
3. **Test** — `.github/agents/Test-Writer.agent.md`
4. **Refactor** — `.github/agents/Refactor-Specialist.agent.md`
5. **Review** — `.github/agents/Code-Critic.agent.md`
6. **Document** — `.github/agents/Doc-Keeper.agent.md`
7. **Create PR**

## Skills (Domain Knowledge)

Read the relevant `SKILL.md` when working in that domain:

| Skill | Path | When to use |
|-------|------|-------------|
| test-driven-development | `.github/skills/test-driven-development/SKILL.md` | Writing tests, red-green-refactor |
| systematic-debugging | `.github/skills/systematic-debugging/SKILL.md` | Investigating complex bugs |
| software-architecture | `.github/skills/software-architecture/SKILL.md` | Evaluating design decisions |
| ui-testing | `.github/skills/ui-testing/SKILL.md` | React component test strategies |
| verification-before-completion | `.github/skills/verification-before-completion/SKILL.md` | Pre-PR readiness checks |

## Shared Instructions

- `.github/instructions/safe-operations.instructions.md` — File operation safety, issue creation rules
- `.github/instructions/tracking-format.instructions.md` — Tracking file format
- `.github/instructions/code-review-intake.instructions.md` — GitHub review intake protocol _(also available as skill: `.github/skills/code-review-intake/SKILL.md`)_
- `.github/instructions/post-pr-review.instructions.md` — Post-merge checklist _(also available as skill: `.github/skills/post-pr-review/SKILL.md`)_

## Related Documentation

- [Architecture Rules](architecture-rules.md)
- [TDD Workflow](.github/skills/test-driven-development/SKILL.md)
