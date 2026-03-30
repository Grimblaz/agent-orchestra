# Project: Order Service

## Overview

Microservice handling order processing for an e-commerce platform. This is an **example** file demonstrating how to configure your project for the multi-agent workflow.

## Technology Stack

- **Language**: Java 21
- **Framework**: Spring Boot 3.2.x
- **Database**: PostgreSQL 15
- **Build Tool**: Gradle 8.x
- **Testing**: JUnit 5, Mockito, TestContainers

## BDD Framework

bdd: true

<!-- Phase 1: BDD is activated solely by the presence of the `## BDD Framework` heading above.
     The `bdd: true` key is reserved for Phase 2 framework mapping (e.g., cucumber.js, behave).
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
