---
name: test-driven-development
description: Test-Driven Development workflow guidance, quality standards, and practical patterns. Use when writing tests first, implementing to pass tests, validating quality gates, or refactoring safely. DO NOT USE FOR: debugging existing failures (use systematic-debugging), React component test patterns (use ui-testing), E2E browser tests (use webapp-testing), randomized property verification (use property-based-testing), or architecture evaluation and design decisions (use software-architecture)
---

<!-- platform-assumptions: markdown skill guidance for VS Code custom agents in Copilot Orchestra; assumes tests are authored against repo-defined commands, architecture rules, and quality thresholds. -->
<!-- markdownlint-disable-file MD041 MD003 MD033 -->

# Test-Driven Development Skill

## Overview

This skill module provides comprehensive TDD workflow guidance, including the RED-GREEN-REFACTOR cycle, quality gates, test patterns, and anti-patterns to avoid.

> **[CUSTOMIZE]** Examples may use a sample stack. Adapt commands and tooling for your project while preserving the same TDD principles.

## Iron Law of TDD

> A behavior is not done until a failing test proves the need, passing tests prove correctness, and refactoring preserves green tests.

<essential_principles>

## TDD Cycle: RED → GREEN → REFACTOR

1. **RED**: Write a failing test that describes the expected behavior
2. **GREEN**: Implement the minimum code to make the test pass
3. **REFACTOR**: Improve code quality while keeping tests green

## Quality Hierarchy

Quality gates are enforced in priority order:

| Priority     | Gate             | Tool                      | Threshold | Enforcement     |
| ------------ | ---------------- | ------------------------- | --------- | --------------- |
| 🥇 PRIMARY   | Mutation Testing | [CUSTOMIZE] Mutation tool | ≥80%      | Blocks merge    |
| 🥈 SECONDARY | Code Coverage    | [CUSTOMIZE] Coverage tool | ≥80%      | Blocks merge    |
| 🥉 BASELINE  | Tests Pass       | [CUSTOMIZE] Test runner   | 100%      | Always required |

**Why this order?**

- Code coverage can be 100% with weak assertions (tests run but don't verify)
- Mutation testing validates that tests actually catch bugs
- Both together ensure comprehensive, high-quality test suites

## Core Testing Principles

- **Test behavior, not implementation**: Test what code should do, not how it does it
- **No reflection hacks**: Don't test private methods via reflection
- **Test rules, not formulas**: "higher values produce larger results" not exact arithmetic
- **Keep test files focused**: Split by behavior if tests become unwieldy

## Behavior Quality Standards

- Use business-language test names that describe expected outcomes, not method names or internal branches
- Prefer one observable behavior per test with a clear Arrange-Act-Assert structure
- Cover realistic edge cases and requirement boundaries, not speculative permutations
- Use parameterized tests for data tables, formulas, or repeated rule checks that differ only by inputs and outcomes
- Treat every added test as a requirement statement; avoid "vibe coding" assertions that do not map to a concrete behavior

## Integration-First Test Strategy

Prefer the narrowest test that still exercises the real behavior, but bias toward integration tests when meaningful behavior depends on collaboration between adjacent components or layers.

- Mock or stub at explicit layer boundaries, not deep inside a layer's own internals
- Exercise adjacent layers together when the architecture permits it, so wiring failures are caught where they matter
- Verify production code paths directly in integration tests; do not simulate the system with custom test helpers that bypass the real integration
- If a test could pass while the production wiring is missing, it is too synthetic for the intended confidence level

### Critical Integration Rule

Integration tests must call actual production code paths, not helper functions that manually recreate the expected side effects.

**Wrong**: A helper mutates state directly and the test asserts on that fake state.

**Right**: The test invokes the real pipeline, service, controller, or workflow that is responsible for the state change.

Why this matters: helper-driven tests can stay green even when the real system is not wired in.

## Quality Gates In Practice

- Run the repository's configured test command for fast red-green feedback
- Use the repository's configured coverage threshold for the domain under test
- Use mutation testing to evaluate assertion strength when the project supports it
- Prefer incremental mutation runs during development and broader validation in CI or completion gates
- Report coverage and mutation results as evidence, not as substitutes for behavior-focused assertions

## Refactor Safely

- Refactor only after the current behavior is proven green
- Remove duplication in tests as long as the behavior remains easy to read
- Keep factories and helpers subordinate to readability; do not hide the behavior under heavy indirection
- When a refactor changes test setup shape, confirm the assertions still describe user-visible or domain-visible behavior

## Collection / Iteration Coverage

For any function that iterates a persisted collection (`getAll()` or
`for...of` across repository results), the test plan **must** include at
least one 2-record scenario that verifies the loop applies semantics to
all members, not only the first or primary record.

- **Single-record fixtures** confirm field-level semantics.
- **Multi-record fixtures** confirm loop-level correctness.

</essential_principles>

<intake>

## What do you need help with?

**TDD Phase:**

1. **write** - Writing tests first (RED phase)
2. **implement** - Making tests pass (GREEN phase)
3. **validate** - Running quality gates (coverage + mutation)
4. **refactor** - Improving code while keeping tests green (REFACTOR phase)
5. **lookup** - Reference information (patterns, commands, anti-patterns)

**What phase are you in?** _(write/implement/validate/refactor/lookup)_

</intake>

<routing>

## Response Routing

| Response             | Workflow/Reference             | Description                                                                     |
| -------------------- | ------------------------------ | ------------------------------------------------------------------------------- |
| write                | workflows/write-tests-first.md | RED phase - write failing tests                                                 |
| implement            | workflows/make-tests-pass.md   | GREEN phase - implement code                                                    |
| validate             | workflows/validate-coverage.md | Run quality gates                                                               |
| refactor             | workflows/refactor-safely.md   | REFACTOR phase - improve code                                                   |
| lookup patterns      | references/test-patterns.md    | AAA, parameterized tests, factories                                             |
| lookup commands      | references/commands.md         | Test commands reference                                                         |
| lookup gates         | references/quality-gates.md    | Thresholds and enforcement                                                      |
| lookup anti-patterns | ## Gotchas (below)             | Summary of what to avoid; see references/anti-patterns.md for detailed examples |

</routing>

<reference_index>

## Reference Files

### Workflows

- `workflows/write-tests-first.md` - RED phase workflow
- `workflows/make-tests-pass.md` - GREEN phase workflow
- `workflows/validate-coverage.md` - Quality gate validation
- `workflows/refactor-safely.md` - REFACTOR phase workflow

### References

- `references/quality-gates.md` - Mutation and coverage thresholds
- `references/test-patterns.md` - AAA pattern, parameterized tests, factories
- `references/anti-patterns.md` - Common anti-patterns to avoid
- `references/commands.md` - Test and validation commands

### Templates

- `templates/test-file.md` - New test file structure
- `templates/describe-block.md` - Behavior-organized test structure

</reference_index>

## Quick Reference

```bash
# [CUSTOMIZE] Replace with your project's test commands

# Run tests
./gradlew test

# Run with coverage (JaCoCo)
./gradlew test jacocoTestReport

# Run mutation testing (PIT)
./gradlew pitest
```

## Gotchas

| Trigger                                                                | Gotcha                                                                               | Fix                                                                              |
| ---------------------------------------------------------------------- | ------------------------------------------------------------------------------------ | -------------------------------------------------------------------------------- |
| Testing a private method via reflection (`setAccessible(true)`)        | Couples test to implementation; breaks on rename or visibility change                | Test through the public interface that exercises the private logic               |
| Asserting `verify(repo, times(1)).findById(...)` instead of the result | Breaks on caching, batching, or any refactor — tests the mechanism, not the behavior | Assert on the returned result or observable side effect, not how it was obtained |
| Testing null/empty inputs that can never occur in the system           | Bloats test suite; encourages defensive code that hides real bugs                    | Test realistic input ranges only; match edge cases to actual system boundaries   |
| `assertThat(health).isEqualTo(150)` with an exact formula match        | Breaks on any formula tweak; encodes the implementation, not the business rule       | Test comparative invariant (`highVit.health > lowVit.health`) not exact values   |
| 100% line coverage with assertions that don't verify correctness       | Coverage is green; mutations survive                                                 | Run mutation testing; require ≥80% score; review asserts on each changed line    |
| Organizing tests as one method per production method                   | Misses behavior variations and error cases; becomes a checklist                      | Organize by scenario/behavior with descriptive names; use `@Nested` groups       |

| Trigger                                                    | Gotcha                                                         | Fix                                                                |
| ---------------------------------------------------------- | -------------------------------------------------------------- | ------------------------------------------------------------------ |
| An integration test uses a helper that sets state directly | The test never proves the real production path or wiring works | Invoke the real service, pipeline, handler, or workflow under test |

| Trigger                                           | Gotcha                                                                | Fix                                                                        |
| ------------------------------------------------- | --------------------------------------------------------------------- | -------------------------------------------------------------------------- |
| Mocking inside a layer instead of at its boundary | Tests become implementation-aware and break during harmless refactors | Stub only the external seam and let the layer's internal collaborators run |

For detailed examples of each anti-pattern, see `references/anti-patterns.md`.
