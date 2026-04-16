<!-- markdownlint-disable MD041 -->

````instructions
# Project: Task Manager API

## Overview

REST API for task management, supporting task creation, assignment, and status tracking. This is an **example** file demonstrating how to configure your project for the multi-agent workflow.

## Technology Stack

- **Language**: TypeScript 5.x (`strict: true`)
- **Framework**: Express 4.x
- **Database**: PostgreSQL 15 (via `pg` / node-postgres)
- **Build Tool**: npm / tsc
- **Testing**: Jest + Supertest

<!-- ## Commit Policy
auto-commit: disabled
To disable Code-Conductor's validated step commits (default-on),
uncomment this section. See CUSTOMIZATION.md#commit-policy for details. -->

## BDD Framework

bdd: cucumber.js

<!-- Phase 2: `bdd: {framework}` enables Gherkin file generation and runner dispatch at CE Gate time.
     Recognized values: cucumber.js, behave, jest-cucumber, cucumber.
     To revert to **Phase 1** (G/W/T scenario authoring only, no Gherkin generation), remove the `bdd:` line but keep the `## BDD Framework` heading.
     To DISABLE BDD, remove the `## BDD Framework` section heading entirely. -->

## Architecture

Layered architecture with strict top-down dependency flow:

```text
┌─────────────────────────────────────────────────┐
│                    Routes                        │
│         (HTTP routing / middleware)             │
├─────────────────────────────────────────────────┤
│                  Controllers                     │
│        (Request parsing, response shaping)      │
├─────────────────────────────────────────────────┤
│                   Services                       │
│              (Business Logic)                   │
├─────────────────────────────────────────────────┤
│                 Repositories                     │
│              (Data Access Layer)                │
└─────────────────────────────────────────────────┘
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

### TypeScript

- **Always** compile with `strict: true` — no `any` type, ever
- Use explicit return types on all exported functions
- Prefer `interface` for object shapes, `type` for unions/aliases
- Use `readonly` for properties that should not be mutated after construction

### Dependency Injection

- Use constructor injection via plain TypeScript classes
- Instantiate the dependency graph in `src/config/container.ts`
- Never `import` a concrete service inside another service — receive it via constructor

### Error Handling

- Throw `AppError` (or a subclass) for all expected domain errors
- `AppError` carries an `httpStatus` and a machine-readable `code`
- The global error middleware in `src/middleware/errorHandler.ts` converts `AppError` to a JSON response
- Never let Express receive an unhandled `Promise` rejection — always `catch` in async route handlers or use the `asyncHandler` wrapper

### Naming Conventions

- Controllers: `*Controller.ts` in `src/controllers/`
- Services: `*Service.ts` in `src/services/`
- Repositories: `*Repository.ts` in `src/repositories/`
- Routes: `*.routes.ts` in `src/routes/`
- Tests: co-located as `*.test.ts` next to the file under test

### API Design

- Follow REST conventions
- Use `express-validator` for request validation
- Return `{ data, meta }` envelope for collections, plain object for single resources
- Return `{ error: { code, message } }` envelope for errors

### Documentation

- JSDoc on every `public` method and exported function
- Include `@param`, `@returns`, and `@throws` where relevant

## Database Conventions

- Use `node-postgres` (`pg`) directly — no ORM
- Run migrations with `node-pg-migrate`; migration files under `migrations/`
- One `Pool` instance shared across the app (created in `src/config/db.ts`)
- Wrap multi-step operations in explicit `BEGIN` / `COMMIT` / `ROLLBACK` transactions
- Never construct SQL strings via string interpolation — always use parameterized queries

## Build & Run

```bash
# Install dependencies
npm install

# Build
npm run build

# Run development server (ts-node-dev with hot reload)
npm run dev

# Run tests
npm test

# Lint / type-check
npm run lint && npm run typecheck
```

## Quick-Validate

```bash
npm run build && npm run lint
```

## Related Documentation

- [Architecture Rules](architecture-rules.md)
- [TDD Workflow](../../.github/skills/test-driven-development/SKILL.md)
````
