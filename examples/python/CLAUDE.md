# Project: Inventory Service

## Overview

REST API for inventory management, supporting product tracking, stock adjustments, and warehouse operations. This is an **example** file demonstrating how to configure `CLAUDE.md` for the multi-agent workflow.

## Technology Stack

- **Language**: Python 3.12
- **Framework**: FastAPI 0.110
- **Database**: PostgreSQL 15 (via SQLAlchemy 2.x ORM)
- **Build Tool**: Poetry
- **Testing**: pytest + httpx

## Architecture

Layered architecture with strict top-down dependency flow:

```text
Routers → Services → Repositories → Models
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

- All function signatures must have type hints (PEP 484)
- `from __future__ import annotations` at top of every module
- `strict = true` in `mypy.ini` — no implicit `Any`
- Pydantic v2 for all request/response bodies (separate Create/Update/Response schemas)
- SQLAlchemy 2.x with `Mapped[T]` and `mapped_column()`
- FastAPI `Depends()` for DI; services receive repos, repos receive sessions
- snake_case everywhere
- Alembic for migrations

## Build & Run

```bash
poetry install                              # Install dependencies
poetry run uvicorn app.main:app --reload    # Run development server
poetry run pytest                           # Run tests
poetry run ruff check . && poetry run mypy . # Lint / type-check
```

## Quick-Validate

```bash
poetry install && poetry run ruff check .
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
| property-based-testing | `.github/skills/property-based-testing/SKILL.md` | Randomized property verification |
| verification-before-completion | `.github/skills/verification-before-completion/SKILL.md` | Pre-PR readiness checks |

## Shared Instructions

- `.github/instructions/safe-operations.instructions.md` — File operation safety, issue creation rules
- `.github/instructions/tracking-format.instructions.md` — Tracking file format
- `.github/instructions/code-review-intake.instructions.md` — GitHub review intake protocol
- `.github/instructions/post-pr-review.instructions.md` — Post-merge checklist

## Related Documentation

- [Architecture Rules](architecture-rules.md)
- [TDD Workflow](.github/skills/test-driven-development/SKILL.md)
