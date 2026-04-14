````instructions
# Project: Inventory Service

## Overview

REST API for inventory management, supporting product tracking, stock adjustments, and warehouse operations. This is an **example** file demonstrating how to configure your project for the multi-agent workflow.

## Technology Stack

- **Language**: Python 3.12
- **Framework**: FastAPI 0.110
- **Database**: PostgreSQL 15 (via SQLAlchemy 2.x ORM)
- **Build Tool**: Poetry
- **Testing**: pytest + httpx

<!-- ## Commit Policy
auto-commit: disabled
To disable Code-Conductor's validated step commits (default-on),
uncomment this section. See CUSTOMIZATION.md#commit-policy for details. -->

## BDD Framework

bdd: behave

<!-- Phase 2: `bdd: {framework}` enables Gherkin file generation and runner dispatch at CE Gate time.
     Recognized values: cucumber.js, behave, jest-cucumber, cucumber.
     To revert to **Phase 1** (G/W/T scenario authoring only, no Gherkin generation), remove the `bdd:` line but keep the `## BDD Framework` heading.
     To DISABLE BDD, remove the `## BDD Framework` section heading entirely. -->

## Architecture

Layered architecture with strict top-down dependency flow:

```text
┌─────────────────────────────────────────────────┐
│                    Routers                       │
│         (HTTP routing / path operations)        │
├─────────────────────────────────────────────────┤
│                   Services                       │
│              (Business Logic)                   │
├─────────────────────────────────────────────────┤
│                 Repositories                     │
│              (Data Access Layer)                │
├─────────────────────────────────────────────────┤
│                    Models                        │
│          (SQLAlchemy ORM / Pydantic)            │
└─────────────────────────────────────────────────┘
```

## Directory Structure

```text
app/
├── routers/             # FastAPI routers (inventory_router.py)
├── services/            # Business logic (inventory_service.py)
├── repositories/        # SQLAlchemy queries (inventory_repository.py)
├── models/              # SQLAlchemy ORM models (inventory.py)
├── schemas/             # Pydantic v2 request/response schemas (inventory_schema.py)
├── errors/              # HTTPException helpers and custom exception types
├── dependencies/        # FastAPI Depends() providers (db.py, auth.py)
├── config/              # Settings via pydantic-settings (settings.py)
└── main.py              # FastAPI app factory
tests/
├── unit/                # Pure unit tests (mocked repos)
├── integration/         # Repository tests against test DB
└── routers/             # Router tests via TestClient / httpx
```

## Key Conventions

### Type Hints

- **All** function signatures must have type hints (PEP 484)
- Use `from __future__ import annotations` at the top of every module
- Enable `strict = true` in `mypy.ini` — no implicit `Any`

### Pydantic Schemas

- Use Pydantic v2 models (`from pydantic import BaseModel`) for all request and response bodies
- Separate `Create*Schema`, `Update*Schema`, and `*Schema` (response) — never reuse the same class for input and output
- Use `model_config = ConfigDict(from_attributes=True)` on response schemas to support ORM mode

### SQLAlchemy ORM

- Use the declarative base (`DeclarativeBase`) for all ORM models
- Define `__tablename__` explicitly on every model
- Always set `nullable=False` explicitly on required columns
- Use `Mapped[T]` and `mapped_column()` (SQLAlchemy 2.x style)

### Error Handling

- Raise `HTTPException` for all expected domain errors; set a meaningful `detail` dict with `code` and `message`
- Define reusable exception helpers in `app/errors/` (e.g., `raise_not_found("Product", product_id)`)
- Never swallow exceptions silently — always log before re-raising unexpected errors

### Naming Conventions

- Routers: `*_router.py` in `app/routers/`
- Services: `*_service.py` in `app/services/`
- Repositories: `*_repository.py` in `app/repositories/`
- ORM Models: `*.py` (domain name) in `app/models/`
- Pydantic Schemas: `*_schema.py` in `app/schemas/`
- Tests: `test_*.py` in `tests/` mirroring the `app/` structure
- snake_case everywhere — variables, functions, modules, columns

### Dependency Injection

- Use FastAPI `Depends()` for injecting the database session and service instances
- Define reusable providers in `app/dependencies/`
- Services receive a repository instance; repositories receive a `Session` — never import session directly in services

## Database Conventions

- Run migrations with Alembic; migration files under `alembic/versions/`
- One `async` session factory shared across the app (via `app/dependencies/db.py`)
- Wrap multi-step mutations in a single `async with session.begin()` context
- Never use raw string interpolation in SQL — always use SQLAlchemy expressions or bound parameters

## Build & Run

```bash
# Install dependencies
poetry install

# Run development server
poetry run uvicorn app.main:app --reload

# Run tests
poetry run pytest

# Lint / type-check
poetry run ruff check . && poetry run mypy .
```

## Quick-Validate

```bash
poetry install && poetry run ruff check .
```

## First-Contact Provenance Gate

When a user-invocable agent receives a request referencing an existing GitHub issue, evaluate whether the issue framing has been validated in the current session before executing.

### Step 1 — Extract issue ID

Parse the user's request for a GitHub issue reference (`#N`, `issue N`, etc.). If no issue ID is determinable, skip the entire gate silently and continue with the user's request.

### Step 2 — Check warm-handoff markers

Check session memory for `plan-issue-{ID}` or `design-issue-{ID}` markers for this issue. Also check GitHub issue comments (via `mcp_github_issue_read` with `method: get_comments`) for `<!-- experience-owner-complete-{ID} -->` or `<!-- design-phase-complete-{ID} -->`. If any are found in either location, the issue framing was already validated — skip the gate silently.

### Step 3 — Check prior assessment marker

Use `mcp_github_issue_read` with `method: get_comments` to check for `<!-- first-contact-assessed-{ID} -->` in the issue's comments. Also check session memory at `/memories/session/first-contact-assessed-{ID}.md` for a prior assessment marker. If found in either location, skip the gate silently (previously assessed). If MCP tools are unavailable or the API call fails, fail open — skip the GitHub marker check and proceed to Step 4.

### Step 4 — Self-filtering

Skip the gate silently for agents with `user-invocable: false` in their frontmatter. Subagents dispatched by Code-Conductor already operate within an assessed session context.

### Step 5 — Run assessment

Load `.github/instructions/provenance-gate.instructions.md` for the full three-question assessment protocol (root cause vs. symptom, mechanism fitness, scope accuracy). If the instructions file is absent (plugin distribution), apply a minimal inline assessment: read the issue body, verify the stated root cause is specific and traceable, and present the developer gate via `#tool:vscode/askQuestions`.

### Step 6 — Record marker

After the developer responds (any option except 'Needs rework — stop here'), post `<!-- first-contact-assessed-{ID} -->` as a GitHub issue comment. If posting fails, record the assessment in session memory at `/memories/session/first-contact-assessed-{ID}.md` instead and proceed. In multi-issue bundles, the gate fires per unique issue ID.

> **See** `.github/instructions/provenance-gate.instructions.md` for the full assessment protocol, edge cases, and known limitations.

## Related Documentation

- [Architecture Rules](architecture-rules.md)
- [TDD Workflow](../../.github/skills/test-driven-development/SKILL.md)
````
