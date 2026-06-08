---
name: implement-test-adapter
provides: implement-test
adapter-type: work
description: "Work adapter for test-authoring slices executed by Senior Engineer"
---

<!-- markdownlint-disable-file MD041 -->

## When to use

### Pick this when

- The frame slice asks for test authoring work for the `implement-test` port.
- Test coverage is needed for behavior that was just implemented in a preceding `implement-code` slice.
- The changeset introduces new production behavior, a new interface contract, or a changed integration point that requires verification evidence.
- BDD-style scenario wiring or React component / UI test patterns are needed for the current slice.

### Don't pick this when

- The slice is for production implementation, documentation, refactoring-only cleanup, UI polish, specification writing, or adversarial review; route those to their own ports.
- The changeset has no testable behavior (e.g., documentation-only edits, config-only changes with no observable effect); route that case to `skills/test-driven-development/adapters/implement-test-auto-na-adapter.md`.
- The test to be authored would require inventing acceptance criteria that are not established by the plan or prior slices.
- The failing test appears to be a bad test (incorrect expectation, mismatch with documented requirement, invalid setup) rather than a product gap; halt with `push-back` and return to the conductor.

## Execution contract

Apply `skills/test-driven-development/SKILL.md` to the behavior established by the current slice. Write tests that verify the production code path described by the acceptance criteria, not implementation internals or speculative future states.

For BDD-style scenario wiring, also consult `skills/bdd-scenarios/SKILL.md`. For React component and UI test patterns, also consult `skills/ui-testing/SKILL.md`. Load these auxiliary skills only when the slice involves BDD or UI testing respectively; do not load them speculatively.

Keep this adapter distinct from `implement-code`: do not add or modify production behavior under a test label. If a production gap must be closed before tests can be authored, halt with `scope-violation` and return the slice to the conductor for the appropriate port.

Use the skill's analysis workflow, mandatory checks, and output structure as the authority for execution details; this adapter only binds that methodology to the `implement-test` port and terminal credit step.

At the terminal credit step, emit the `implement-test` credit row with the existing `Build-ImplementTestCreditRow` builder. This adapter authors the instruction only; do not invoke the builder while creating or editing this file.

Pass the repo-relative adapter path as adapter evidence by setting `-AdapterName 'skills/test-driven-development/adapters/implement-test-adapter.md'`, include validation evidence from the test-authoring validation cycle with `-ValidationEvidence`, include a concise execution summary with `-Evidence`, and pass the terminal slice step number with `-Step`. In the example below, replace `{terminal-step-id}` with that numeric terminal slice step number.

Example invocation shape:

```powershell
Build-ImplementTestCreditRow `
  -AdapterName 'skills/test-driven-development/adapters/implement-test-adapter.md' `
  -ValidationEvidence @(@{ Name = 'focused test validation'; Status = 'passed' }) `
  -Evidence 'skills/test-driven-development/adapters/implement-test-adapter.md executed with test-authoring validation evidence.' `
  -Step {terminal-step-id}
```

Use the additive-merge rule for the PR-body `<!-- pipeline-metrics -->` block: if an `implement-test` credit row already exists for the same terminal step, leave it in place.
