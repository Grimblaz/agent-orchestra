# Design: Migration Safety

## Overview

Security-sensitive field carve-out for data migration overwrite operations. Prevents silent overwrite of auth hashes, tokens, and permission flags during full-record migration operations.

## Problem

Full-record overwrite operations (e.g., `setDoc`, `replaceOne`, `session.merge`, `repository.save`) can silently replace security-sensitive target values with stale or attacker-controlled source values during data migrations — especially when conflict resolution is deferred.

## Design Decisions

### D1 — Narrow planning gate

Issue-Planner RC rule fires only on explicit deferral of conflict resolution in migration plans. Requires enumerating security-sensitive fields and their merge semantics, or explicitly stating none exist.

### D2 — Review-time defense-in-depth

Code-Critic Security Perspective checklist item catches broader full-record overwrite patterns at review time, independent of the planning gate.

### D3 — Zero-clutter templates

Example architecture-rules files provide HTML-commented starter sections that render invisibly until consumer teams uncomment and customize.

## Implementation

| Touch point | Location |
|---|---|
| Issue-Planner RC rule | `<plan_style_guide>` in `.github/agents/Issue-Planner.agent.md` |
| Code-Critic checklist | 5th item in Security Perspective, `.github/agents/Code-Critic.agent.md` |
| Node.js/Firestore template | `examples/nodejs-typescript/architecture-rules.md` |
| Python/SQLAlchemy template | `examples/python/architecture-rules.md` |
| Java/JPA template | `examples/spring-boot-microservice/architecture-rules.md` |

Each example template contains an HTML-commented `## Migration Safety` section with stack-specific UNSAFE→SAFE code patterns. Teams uncomment and customize for their domain.

## Three-Layer Defense Chain

1. **Plan-time enforcement** — Issue-Planner RC rule gates plan creation when conflict resolution is deferred in migration plans.
2. **Review-time enforcement** — Code-Critic Security Perspective checklist gates code review for full-record overwrite patterns.
3. **Template guidance** — Example files provide copy-paste-ready safe patterns (guidance, not enforcement).

## Related

- Issue [#291](https://github.com/Medevs/Copilot-Orchestra/issues/291)
- Consumer repo issue: Windgust-Questbook #157
