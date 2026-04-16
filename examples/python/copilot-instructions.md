<!-- markdownlint-disable MD041 -->

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

## Related Documentation

- [Architecture Rules](architecture-rules.md)
- [TDD Workflow](../../.github/skills/test-driven-development/SKILL.md)
````
