---
name: test-driven-development
description: "Test-Driven Development workflow guidance, quality standards, and practical patterns. Use when writing tests first, implementing to pass tests, validating quality gates, or refactoring safely; also when placing a hazardous or non-returning test file, when changing CI suite selection or a dot-sourced runner library, when a suite passes locally and fails only on CI, when claiming a rule is covered by the surrounding tests, when writing a test docstring that names a cross-surface invariant, and when writing a test that fabricates hostile input. DO NOT USE FOR: debugging existing failures (use systematic-debugging), React component test patterns (use ui-testing), E2E browser tests (use webapp-testing), randomized property verification (use property-based-testing), or architecture evaluation and design decisions (use software-architecture)"
---

<!-- platform-assumptions: markdown skill guidance for VS Code custom agents in Agent Orchestra; assumes tests are authored against repo-defined commands, architecture rules, and quality thresholds. -->
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

Example anti-pattern:

```typescript
function markAsProcessed(record: WorkItem): void {
  record.status = "processed";
}
```

Preferred shape:

```typescript
const processor = new ProcessingPipeline(...);
processor.execute(record, context);
expect(record.status).toBe("processed");
```

Why this matters: a helper-driven integration test can stay green even when the real production wiring is missing.

### Producer-Shape Fidelity

A fixture for a function whose input comes from a _named upstream producer_ (a parser, converter, deserializer, or dot-sourced library call) must use the producer's actual runtime type, verified by reading the producer — not whichever type is easiest to construct in the test language.

**Trap**: a `[pscustomobject]` fixture can make a `.PSObject.Properties.Match(...)` check pass while the real shape (`[hashtable]`, e.g. from a YAML/JSON parser) makes the same check silently no-op in production.

This is _type_ fidelity — distinct from the path-wiring fidelity above and the cardinality fidelity in Collection / Iteration Coverage below. Mutation testing cannot catch it: mutations only prove tests catch changes within the fixture's own shape.

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

## Composite References

- [references/anti-patterns.md](references/anti-patterns.md): test anti-patterns and what to write instead
- [references/commands.md](references/commands.md): per-stack test invocation commands
- [references/quality-gates.md](references/quality-gates.md): the quality-gate tiers and what each one asserts
- [references/test-patterns.md](references/test-patterns.md): reusable test shapes for the common cases
- [references/test-authoring-exhibits.md](references/test-authoring-exhibits.md): the incident detail behind § Test-Authoring Lenses — the placements, leaks, false greens and undefended rules each lens was extracted from

## Reference Files

### Workflows

- `workflows/write-tests-first.md` - RED phase workflow
- `workflows/make-tests-pass.md` - GREEN phase workflow
- `workflows/validate-coverage.md` - Quality gate validation
- `workflows/refactor-safely.md` - REFACTOR phase workflow

### References

> Note: ## Composite References above is the complete list for this directory and is what the promotion check reads. This older grouping is kept for its per-file commentary and does not include eferences/test-authoring-exhibits.md.

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

## Test-Authoring Lenses

> **Authoritative source**: which lessons are promoted here, what anchor each one lives at, and the trigger text that has to reach a reader are recorded in `Documents/Planning/lesson-promotion-manifest.json`. `.github/scripts/Tests/lesson-promotion-manifest.Tests.ps1` is what stops this section and that manifest drifting apart, and it is the suite a red comes from. **Renaming a heading below is a migration, not a regression** — update that lesson's `anchor` in the manifest in the same commit as the rename. A red naming an anchor you just renamed is reporting a manifest row left behind, not a lost lens.

Six ways a suite is green about the wrong thing. Incident detail sits in [references/test-authoring-exhibits.md](references/test-authoring-exhibits.md), cited per lens.

#### Blast radius comes from what executes a path, not from what selects from it

Before placing anything hazardous — a deliberately non-returning control suite, a fixture that must never be collected — **grep for what runs that path, not for what filters it**. A selector and an executor are different things, and safety is a property of the executors. Checking every selector in the repository and finding them all non-recursive and all agreeing on a file count reads as safety while the consumers that would actually hang were never in the searched set: directory-level test invocations, the commands documented in contributor instructions and pull-request templates, baseline-capture helpers. Pester's directory discovery is **recursive**, so a subdirectory placement that the non-recursive gate glob never yields still lands inside the loop every contributor runs before opening a pull request, on a machine with no job ceiling to stop it. And a quarantine entry cannot rescue it: **the registry binds the gate's *selection*, not a raw directory run**, so an entry protects CI and leaves every human exposed. Only outside the tests root is actually safe; the convention that has kept this from biting is that fixtures under that root do not carry the suite suffix. Exhibit: [references/test-authoring-exhibits.md](references/test-authoring-exhibits.md) § A "safe" placement inside the pre-PR command.

#### CI selects suites by glob minus the quarantine registry, and a file-scope StrictMode in a dot-sourced library reddens the whole run

Suite selection here is a **glob minus `.github/scripts/Tests/ci-quarantine.json`**, not an allowlist — there is nothing to forget to update, and skipping a suite means adding an entry with a `class` and a `reason`. Keep the classes distinct: never-measured backlog, measured-failing (which requires an issue number, because a temporary exclusion with no ticket is a permanent one that has not admitted it), and structurally-cannot-run. Collapsing them is how a registry becomes a graveyard nobody reads. The trap that ships alongside: **a file-scope `Set-StrictMode` in a library the workflow dot-sources leaks into the entire Pester run**, because the workflow dot-sources and then invokes in the same session — so strictness applies to every suite executed afterwards and reddens subsystems the change never touched. A library dot-sourced by a *runner* sets strictness **inside its functions**; file scope is only safe for libraries dot-sourced inside a `BeforeAll`, where the blast radius is one file. The verification method worth reusing for any of this: **do not approximate a workflow locally — extract its own `run:` block from the YAML and execute those exact bytes** in a fresh process, swapping the exit-on-failure setting for pass-through. A hand-rolled approximation dot-sources in a different order and misses exactly this class. Exhibit: [references/test-authoring-exhibits.md](references/test-authoring-exhibits.md) § A StrictMode leak that reddened 218 untouched tests.

#### For a CI-only failure, dump the whole decision state in one run

One hypothesis per round-trip is the slow, wrong method: each narrow assertion comes back clean and kills its hypothesis without pointing anywhere. Push a temporary block that dumps **everything the decision reads plus the product's own output**, unconditionally, written so it lands in the log whether or not the assertion fails. Capture, roughly in value order: the product's own log lines (usually decisive — the executor naming which branch it took ends the search instantly); every probe's exit code *and* its stdout, not just the boolean you derive from it; the identity facts side by side (the SHAs and refs the decision compares); tool versions and relevant configuration; and whether the mocks were reached at all, since an empty call log is a loud signal. Two traps this method catches: **a shim that only works on one platform makes tests pass for the wrong reason** — every fixture expecting a decline still passes when the tool is simply unavailable, so assert the mock was actually invoked; and a cherry-pick can reproduce a source commit's exact SHA when tree, parent, message, author and committer-second all match, so the branch has zero unique commits and the test silently exercises another path. General rule: a test depending on an unasserted precondition reports the *downstream* symptom — pin the precondition and the failure names itself. Exhibit: [references/test-authoring-exhibits.md](references/test-authoring-exhibits.md) § Three CI round-trips against one dump.

#### A rule you cannot invoke cannot be defended, however many tests surround it

If a rule lives inline — a `Where-Object` block, a condition inside a long function — and the only path reaching it runs behind a worker-runspace boundary, a fail-open `catch`, or a guard with conjuncts you cannot satisfy hermetically, then **no test can drive it**: reverting the rule leaves the whole repository green. That is not "covered by the surrounding tests", it is undefended, and prose saying it "moved in lockstep" reads as defended. **Before claiming a rule is defended, revert it in a scratch tree and run everything — per rule, not per file.** A rule with no reachable red state gets one of exactly two things: **extraction into a named, callable unit** the real code path then calls, or an explicit written record that it ships undefended. The bigger harness is not the fix; testability is a design property of where you put the rule, not of how many tests you wrote. Exhibit: [references/test-authoring-exhibits.md](references/test-authoring-exhibits.md) § A reverted rule that left 23 tests green.

#### A test docstring can name a check the body never performs

When a docstring names a cross-surface invariant, check the body actually **reads both surfaces**. A test that enumerates a constant it also authored is self-consistent by construction and can never fail for the reason its documentation gives — and the unwritten check is usually exactly what would have caught the defect sitting next to it, so the overclaim and the gap are one hole seen from two sides. Read the canonical source at runtime instead of typing out a hashtable. The corollary that rides along: an **absence-assertion set is only as good as its enumeration** — pinning that three moved sections are gone while silently omitting a fourth means a re-addition passes everything. And always run the negative control: after fixing, restore the pre-fix file and confirm the new tests actually fail against it; a test that passes both before and after is correctly identified as covering already-working behaviour, not as evidence. Exhibit: [references/test-authoring-exhibits.md](references/test-authoring-exhibits.md) § A docstring that named a check the body never ran.

#### A test that fabricates hostile input can corrupt the aggregate artifact it protects

When the property under test is a property of the **whole run's output**, a test that fabricates an adversarial input can satisfy itself and break that property at the same time — unit-level green says nothing, and only the aggregate re-run shows it. Before writing such a test, ask: *does this test run inside the artifact whose aggregate property I am protecting?* If yes, resolve the adversarial cases through the **pure helper** so nothing is emitted, and keep only end-to-end cases whose output is indistinguishable from a legitimate participant. Watch the harness too, not just your code: a runner that echoes the path of every file it executes will inject a record-shaped string into the same log from a **fixture directory name**, which is the reading hazard the criterion existed to remove, emitted from a line the code never wrote. And check the aggregate rather than the unit — where a criterion is stated over a whole run, the verification has to be a whole run. Exhibit: [references/test-authoring-exhibits.md](references/test-authoring-exhibits.md) § A test that stamped six false records into its own run.

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

## Frame Ports Filled By This Skill

| Port | Work adapter | Auto-N/A adapter | Explicit-skip adapter |
| --- | --- | --- | --- |
| `implement-test` | [agents/Test-Writer.agent.md](../../agents/Test-Writer.agent.md); [adapters/implement-test-adapter.md](adapters/implement-test-adapter.md) | [adapters/implement-test-auto-na-adapter.md](adapters/implement-test-auto-na-adapter.md) | [adapters/implement-test-explicit-skip-adapter.md](adapters/implement-test-explicit-skip-adapter.md) |

In `/spine-run`, the `implement-test` port resolves through [adapters/implement-test-adapter.md](adapters/implement-test-adapter.md) as the work adapter executed by Senior Engineer. Hub-flow dispatch uses `agents/Test-Writer.agent.md` directly. This split-declaration state is documented in [Documents/Design/frame-architecture.md](../../Documents/Design/frame-architecture.md); see footnote ‡ (split-declaration #612).

## Cross-platform path conventions

When authoring tests that reference filesystem paths via `Join-Path`, use forward
slashes in child-path arguments. See `.github/architecture-rules.md §Validation`
for the authoritative convention and enforcement gate.
