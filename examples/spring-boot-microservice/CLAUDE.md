# Project: Order Service

## Overview

Microservice handling order processing for an e-commerce platform. This is an **example** file demonstrating how to configure `CLAUDE.md` for the multi-agent workflow.

## Technology Stack

- **Language**: Java 21
- **Framework**: Spring Boot 3.2.x
- **Database**: PostgreSQL 15
- **Build Tool**: Gradle 8.x
- **Testing**: JUnit 5, Mockito, TestContainers

## Architecture

Layered architecture following Domain-Driven Design principles:

```text
Controllers → Services → Repositories → Entities
```

## Package Structure

```text
com.example.orderservice/
├── controller/          # REST endpoints
├── service/             # Business logic
├── repository/          # Data access
├── entity/              # JPA entities
├── dto/                 # Request/Response DTOs
├── mapper/              # Entity ↔ DTO mappers
├── exception/           # Custom exceptions
├── config/              # Configuration classes
└── client/              # External service clients
```

## Key Conventions

- Constructor injection with `@RequiredArgsConstructor` (Lombok) — avoid `@Autowired` on fields
- `@ControllerAdvice` for global exception handling with `ProblemDetail` (RFC 7807)
- `@Valid` for request validation, OpenAPI/Swagger annotations for docs
- Unit tests for services (mock deps), integration tests for repos (TestContainers), API tests (MockMvc)
- Flyway migrations: `V{version}__{description}.sql`
- No `@GeneratedValue(strategy = AUTO)` — use `IDENTITY` or `SEQUENCE`
- `RestClient` (Spring 6.1+) for HTTP calls, Resilience4j for circuit breakers

## Build & Run

```bash
./gradlew build       # Build
./gradlew test        # Run tests
./gradlew bootRun     # Run application
./gradlew bootBuildImage  # Build Docker image
```

## Quick-Validate

```bash
./gradlew build
```

## Workflow for Claude Code

Follow the phased workflow. Each phase references a role guide in the copilot-orchestra repo:

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
| test-driven-development | `.github/skills/test-driven-development/SKILL.md` | Writing tests first, red-green-refactor, or quality gates |
| systematic-debugging | `.github/skills/systematic-debugging/SKILL.md` | Debugging failures, flaky tests, or tracking root causes |
| software-architecture | `.github/skills/software-architecture/SKILL.md` | Layer boundaries, dependency flow, or ADR-level decisions |
| verification-before-completion | `.github/skills/verification-before-completion/SKILL.md` | Before PRs, releases, or any completion declaration |

## Shared Instructions

- `.github/instructions/safe-operations.instructions.md` — File operation safety, issue creation rules
- `.github/instructions/tracking-format.instructions.md` — Tracking file format
- `.github/instructions/code-review-intake.instructions.md` — GitHub review intake protocol _(also available as skill: `.github/skills/code-review-intake/SKILL.md`)_
- `.github/instructions/post-pr-review.instructions.md` — Post-merge checklist _(also available as skill: `.github/skills/post-pr-review/SKILL.md`)_

## Related Documentation

- [Architecture Rules](architecture-rules.md)
- [Tech Debt Tracking](TECH-DEBT.md)
- [TDD Workflow](.github/skills/test-driven-development/SKILL.md)
