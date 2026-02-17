---
name: software-architecture
description: Clean Architecture, SOLID principles, and architectural decision guidance. Use when designing systems, evaluating architecture, making structural decisions, or reviewing for maintainability.
---

# Software Architecture Skill

High-level architectural patterns and decision-making frameworks.

## When to Use

- Designing new systems or major features
- Evaluating existing architecture
- Making structural decisions (layer boundaries, dependencies)
- Reviewing code for architectural alignment
- Documenting architectural decisions (ADRs)

## SOLID Principles Quick Reference

| Principle | Summary | Violation Smell |
|-----------|---------|-----------------|
| **S**ingle Responsibility | One reason to change | Class does too many things |
| **O**pen/Closed | Extend, don't modify | Modifying existing code for new features |
| **L**iskov Substitution | Subtypes are substitutable | Overrides that break expectations |
| **I**nterface Segregation | Small, focused interfaces | Implementing methods you don't need |
| **D**ependency Inversion | Depend on abstractions | High-level imports low-level directly |

## Clean Architecture Layers

```
┌─────────────────────────────────────────┐
│           External Systems              │  Frameworks, DB, UI
├─────────────────────────────────────────┤
│           Interface Adapters            │  Controllers, Presenters, Gateways
├─────────────────────────────────────────┤
│           Application Layer             │  Use Cases, Application Services
├─────────────────────────────────────────┤
│           Domain Layer                  │  Entities, Value Objects, Domain Services
└─────────────────────────────────────────┘
         Dependencies point INWARD →
```

### Layer Responsibilities

**Domain Layer** (innermost):
- Business entities and logic
- No dependencies on outer layers
- Framework-agnostic

**Application Layer**:
- Use case orchestration
- Application-specific business rules
- Coordinates domain objects

**Interface Adapters**:
- Convert data between layers
- Controllers, presenters, gateways
- Maps to/from domain models

**External Systems** (outermost):
- Frameworks, databases, UI
- All implementation details
- Easily replaceable

## Dependency Rule

> Source code dependencies must point only inward, toward higher-level policies.

**Good**: Controller → Use Case → Entity
**Bad**: Entity → Database (domain knows about infrastructure)

## Common Architectural Patterns

### Hexagonal Architecture (Ports & Adapters)
```
         ┌──────────────┐
 Driving │              │ Driven
 Adapters│    Core      │ Adapters
 (Input) │   Domain     │ (Output)
    ────>│              │────>
         └──────────────┘
           Ports (Interfaces)
```

### CQRS (Command Query Responsibility Segregation)
- Separate read and write models
- Use when read/write patterns differ significantly
- Consider eventual consistency implications

### Event-Driven Architecture
- Loose coupling through events
- Good for: cross-boundary communication, audit trails
- Consider: event ordering, idempotency, replay

## Architectural Decision Framework

When making architectural decisions:

### 1. Identify the Decision
- What specific decision needs to be made?
- What are the constraints?
- Who are the stakeholders?

### 2. Gather Context
- What are the requirements (functional and non-functional)?
- What are the quality attributes (performance, scalability, etc.)?
- What are the constraints (time, budget, team skills)?

### 3. Evaluate Options
For each option, consider:
- **Benefits**: What problems does it solve?
- **Costs**: Implementation effort, maintenance, complexity
- **Risks**: What could go wrong?
- **Trade-offs**: What are we giving up?

### 4. Document Decision (ADR)
```markdown
# ADR-XXX: [Title]

## Status
[Proposed | Accepted | Deprecated | Superseded]

## Context
[What is the issue that we're seeing that is motivating this decision?]

## Decision
[What is the change that we're proposing and/or doing?]

## Consequences
[What becomes easier or harder as a result of this change?]
```

## Code-Level Architecture Patterns

### Dependency Injection
```
[CUSTOMIZE] Add your DI framework examples:
// Framework: [Your framework]
// Pattern: [Constructor injection, etc.]
```

### Repository Pattern
```
Interface: Repository<T>
  - findById(id): T
  - save(entity): void
  - delete(id): void

Implementation in infrastructure layer
Domain layer depends only on interface
```

### Service Layer
```
Thin controllers → Application Services → Domain
Controllers: HTTP handling only
Services: Use case orchestration
Domain: Business logic
```

## Architectural Smells

| Smell | Symptom | Remedy |
|-------|---------|--------|
| Big Ball of Mud | Everything depends on everything | Define boundaries |
| Distributed Monolith | Microservices with tight coupling | Find real boundaries |
| Anemic Domain Model | Logic in services, entities are data bags | Rich domain model |
| God Object | Class that knows/does too much | Split responsibilities |
| Circular Dependencies | A→B→C→A | Introduce abstractions |

## Review Checklist

When reviewing architecture:

### Boundaries
- [ ] Clear layer/module boundaries defined
- [ ] Dependencies flow in correct direction
- [ ] Boundaries match team structure (Conway's Law)

### Coupling
- [ ] Low coupling between modules
- [ ] Changes are localized
- [ ] Can deploy independently (if relevant)

### Cohesion
- [ ] Related things are together
- [ ] Modules have clear, single purpose
- [ ] Naming reflects responsibility

### Testability
- [ ] Can test business logic without infrastructure
- [ ] Dependencies are injectable
- [ ] Seams exist for test doubles

## Project-Specific Architecture

[CUSTOMIZE] Document your project's architecture:

```markdown
## Architecture Overview
[Diagram or description of your architecture]

## Layer Structure
- Domain: [location]
- Application: [location]
- Infrastructure: [location]
- Presentation: [location]

## Key Patterns Used
- [Pattern 1]: [Where/why used]
- [Pattern 2]: [Where/why used]

## Architecture Decision Log
- [Link to ADRs or decision log]
```
