<!-- markdownlint-disable-file MD041 MD003 -->
<!-- platform-assumptions: markdown skill guidance for VS Code custom agents in Copilot Orchestra; outputs repository-local specification documents. -->
---

name: specification-authoring
description: Structured authoring guidance for formal specification documents. Use when drafting machine-readable requirements, filling the repository specification template, or refining interfaces and acceptance criteria into a self-contained spec. DO NOT USE FOR: implementation planning (use plan-authoring) or broad design exploration (use brainstorming)
---

# Specification Authoring

Reusable process for drafting precise, self-contained specification documents.

## When to Use

- When a formal specification document must be created or updated
- When requirements, constraints, interfaces, and acceptance criteria need a machine-readable structure
- When a specification must be complete enough for downstream implementation or review without hidden context
- When examples and edge cases need to be captured in a durable spec format

## Purpose

Produce specifications that read as contracts, not notes. Every requirement should be explicit, scoped, and testable, with a structure that downstream humans and models can parse consistently.

## Authoring Principles

- Use precise, unambiguous language
- Distinguish requirements, constraints, recommendations, and patterns explicitly
- Prefer structured sections, tables, and numbered requirement IDs over narrative prose
- Define acronyms, domain terms, and assumptions in the document itself
- Include examples and edge cases when they materially reduce ambiguity
- Keep the document self-contained unless an external reference is truly authoritative and unavoidable

## Authoring Workflow

1. Clarify the specification scope, audience, and primary purpose.
2. Gather the constraints, interfaces, dependencies, and acceptance criteria that belong in the contract.
3. Fill the full repository specification template in order.
4. Convert vague statements into explicit requirements, constraints, or guidelines.
5. Add concrete examples and edge cases where ambiguity would otherwise remain.
6. Verify the document is internally consistent and does not depend on unstated context.

## Required Template

````md
---
title: [Concise Title Describing the Specification's Focus]
version: [Optional: e.g., 1.0, Date]
date_created: [YYYY-MM-DD]
last_updated: [Optional: YYYY-MM-DD]
owner: [Optional: Team/Individual responsible for this spec]
tags: [Optional: List of relevant tags or categories, e.g., `infrastructure`, `process`, `design`, `app` etc]
---

# Introduction

[A short concise introduction to the specification and the goal it is intended to achieve.]

## 1. Purpose & Scope

[Provide a clear, concise description of the specification's purpose and the scope of its application. State the intended audience and any assumptions.]

## 2. Definitions

[List and define all acronyms, abbreviations, and domain-specific terms used in this specification.]

## 3. Requirements, Constraints & Guidelines

[Explicitly list all requirements, constraints, rules, and guidelines. Use bullet points or tables for clarity.]

- **REQ-001**: Requirement 1
- **SEC-001**: Security Requirement 1
- **[3 LETTERS]-001**: Other Requirement 1
- **CON-001**: Constraint 1
- **GUD-001**: Guideline 1
- **PAT-001**: Pattern to follow 1

## 4. Interfaces & Data Contracts

[Describe the interfaces, APIs, data contracts, or integration points. Use tables or code blocks for schemas and examples.]

## 5. Acceptance Criteria

[Define clear, testable acceptance criteria for each requirement using Given-When-Then format where appropriate.]

- **AC-001**: Given [context], When [action], Then [expected outcome]
- **AC-002**: The system shall [specific behavior] when [condition]
- **AC-003**: [Additional acceptance criteria as needed]

## 6. Test Automation Strategy

[Define the testing approach, frameworks, and automation requirements.]

- **Test Levels**: Unit, Integration, End-to-End
- **Frameworks**: Project-approved test frameworks (see `.github/copilot-instructions.md`)
- **Test Data Management**: [approach for test data creation and cleanup]
- **CI/CD Integration**: [automated testing in GitHub Actions pipelines]
- **Coverage Requirements**: [minimum code coverage thresholds]
- **Performance Testing**: [approach for load and performance testing]

## 7. Rationale & Context

[Explain the reasoning behind the requirements, constraints, and guidelines. Provide context for design decisions.]

## 8. Dependencies & External Integrations

[Define the external systems, services, and architectural dependencies required for this specification. Focus on **what** is needed rather than **how** it's implemented. Avoid specific package or library versions unless they represent architectural constraints.]

### External Systems

- **EXT-001**: [External system name] - [Purpose and integration type]

### Third-Party Services

- **SVC-001**: [Service name] - [Required capabilities and SLA requirements]

### Infrastructure Dependencies

- **INF-001**: [Infrastructure component] - [Requirements and constraints]

### Data Dependencies

- **DAT-001**: [External data source] - [Format, frequency, and access requirements]

### Technology Platform Dependencies

- **PLT-001**: [Platform/runtime requirement] - [Version constraints and rationale]

### Compliance Dependencies

- **COM-001**: [Regulatory or compliance requirement] - [Impact on implementation]

**Note**: This section should focus on architectural and business dependencies, not specific package implementations. For example, specify "OAuth 2.0 authentication library" rather than a framework-specific package name and version.

## 9. Examples & Edge Cases

```code
// Code snippet or data example demonstrating the correct application of the guidelines, including edge cases
```

## 10. Validation Criteria

[List the criteria or tests that must be satisfied for compliance with this specification.]

## 11. Related Specifications / Further Reading

[Link to related spec 1]
[Link to relevant external documentation]
````

## Quality Checklist

- Requirements use stable IDs and testable wording
- Constraints and recommendations are not mixed together
- Interfaces and dependencies describe the contract, not incidental implementation details
- Acceptance criteria can be validated without guessing at intent
- Definitions section covers every acronym and domain-specific term that could confuse a reader

## Related Guidance

- Load `software-architecture` when the specification defines architectural constraints or layer boundaries
- Load project-specific skills when documenting domain rules or framework-specific constraints

## Gotchas

| Trigger                                    | Gotcha                                                           | Fix                                                                 |
| ------------------------------------------ | ---------------------------------------------------------------- | ------------------------------------------------------------------- |
| Writing recommendations as requirements    | The spec over-commits optional guidance as mandatory behavior    | Label requirements, constraints, and guidelines separately          |

| Trigger                                  | Gotcha                                                          | Fix                                                                 |
| ---------------------------------------- | --------------------------------------------------------------- | ------------------------------------------------------------------- |
| Depending on unstated repo context       | Readers cannot implement or review the spec without side input  | Expand definitions, assumptions, and interfaces until self-contained |
