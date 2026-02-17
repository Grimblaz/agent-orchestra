---
name: test-driven-development
description: Test-Driven Development workflow guidance, quality standards, and practical patterns. Use when writing tests first, implementing to pass tests, validating quality gates, or refactoring safely.
---

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

| Response             | Workflow/Reference             | Description                         |
| -------------------- | ------------------------------ | ----------------------------------- |
| write                | workflows/write-tests-first.md | RED phase - write failing tests     |
| implement            | workflows/make-tests-pass.md   | GREEN phase - implement code        |
| validate             | workflows/validate-coverage.md | Run quality gates                   |
| refactor             | workflows/refactor-safely.md   | REFACTOR phase - improve code       |
| lookup patterns      | references/test-patterns.md    | AAA, parameterized tests, factories |
| lookup commands      | references/commands.md         | Test commands reference             |
| lookup gates         | references/quality-gates.md    | Thresholds and enforcement          |
| lookup anti-patterns | references/anti-patterns.md    | What to avoid                       |

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
