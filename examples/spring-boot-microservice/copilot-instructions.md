# Project: Order Service

## Overview

Microservice handling order processing for an e-commerce platform. This is an **example** file demonstrating how to configure your project for the multi-agent workflow.

## Technology Stack

- **Language**: Java 21
- **Framework**: Spring Boot 3.2.x
- **Database**: PostgreSQL 15
- **Build Tool**: Gradle 8.x
- **Testing**: JUnit 5, Mockito, TestContainers

<!-- ## Commit Policy
auto-commit: disabled
To disable Code-Conductor's validated step commits (default-on),
uncomment this section. See CUSTOMIZATION.md#commit-policy for details. -->

## BDD Framework

bdd: cucumber

<!-- Phase 2: `bdd: {framework}` enables Gherkin file generation and runner dispatch at CE Gate time.
     Recognized values: cucumber.js, behave, jest-cucumber, cucumber.
     To revert to **Phase 1** (G/W/T scenario authoring only, no Gherkin generation), remove the `bdd:` line but keep the `## BDD Framework` heading.
     To DISABLE BDD, remove the `## BDD Framework` section heading entirely. -->

## Architecture

Layered architecture following Domain-Driven Design principles:

```text
┌─────────────────────────────────────────────────┐
│                  Controllers                     │
│            (REST API / HTTP Handling)           │
├─────────────────────────────────────────────────┤
│                   Services                       │
│              (Business Logic)                   │
├─────────────────────────────────────────────────┤
│                 Repositories                     │
│              (Data Access Layer)                │
├─────────────────────────────────────────────────┤
│                   Entities                       │
│              (Domain Models)                    │
└─────────────────────────────────────────────────┘
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

### Dependency Injection

- **Always** use constructor injection
- Use `@RequiredArgsConstructor` from Lombok
- Avoid `@Autowired` on fields

### Naming Conventions

- Controllers: `*Controller` (e.g., `OrderController`)
- Services: `*Service` (e.g., `OrderService`)
- Repositories: `*Repository` (e.g., `OrderRepository`)
- DTOs: `*Request`, `*Response`, `*Dto`
- Entities: Business domain names (e.g., `Order`, `OrderItem`)

### Error Handling

- Use `@ControllerAdvice` for global exception handling
- Return `ProblemDetail` (RFC 7807) for error responses
- Create domain-specific exceptions extending `RuntimeException`

### API Design

- Follow REST conventions
- Use `@Valid` for request validation
- Return appropriate HTTP status codes
- Document with OpenAPI/Swagger annotations

### Testing

- Unit tests for services (mock dependencies)
- Integration tests for repositories (TestContainers)
- API tests for controllers (MockMvc)
- Follow TDD workflow from `.github/skills/test-driven-development/`

## Database Conventions

- Use Flyway for migrations
- Migration files: `V{version}__{description}.sql`
- No `@GeneratedValue(strategy = AUTO)` - use `IDENTITY` or `SEQUENCE`
- Always define foreign key constraints

## External Dependencies

When interacting with external services:

- Use `RestClient` (Spring 6.1+) or `WebClient` for HTTP calls
- Implement circuit breakers with Resilience4j
- Define response timeout configurations
- Log external call metrics

## Build & Run

```bash
# Build
./gradlew build

# Run tests
./gradlew test

# Run application
./gradlew bootRun

# Build Docker image
./gradlew bootBuildImage
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
- [Tech Debt Tracking](TECH-DEBT.md)
- [TDD Workflow](../../.github/skills/test-driven-development/SKILL.md)
