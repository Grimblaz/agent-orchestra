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

## Related Documentation

- [Architecture Rules](architecture-rules.md)
- [Tech Debt Tracking](TECH-DEBT.md)
- [TDD Workflow](../../.github/skills/test-driven-development/SKILL.md)
