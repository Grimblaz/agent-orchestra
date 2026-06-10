---
name: implement-code-adapter
provides: implement-code
adapter-type: work
description: "Work adapter for bounded, requirements-first implementation slices executed by Senior Engineer"
---

<!-- markdownlint-disable-file MD041 -->

## When to use

### Pick this when

- The frame slice asks for production implementation work for the `implement-code` port.
- The requirements, acceptance criteria, or failing behavior are specific enough to implement without inventing product scope.
- The work can be completed by changing the smallest set of production files needed to satisfy the current requirement.
- Existing tests or validation commands can produce evidence that the implementation is wired into the product path.

### Don't pick this when

- The slice is primarily test authoring, documentation, refactoring-only cleanup, UI polish, specification writing, or adversarial review.
- The requirement is ambiguous enough that implementation would require guessing customer intent, architecture, or acceptance criteria.
- The requested change would cross layer boundaries, introduce unjustified complexity, or widen scope beyond the dispatched slice.
- The current failure appears to be caused by an incorrect test expectation or invalid test setup rather than a product gap.

## Execution contract

Apply `skills/implementation-discipline/SKILL.md` to the dispatched slice. Use the skill's pre-implementation review, implementation standards, halt-return conditions, and requirements verification as the authority for execution details; this adapter only binds that methodology to the `implement-code` port and terminal credit step.

Keep this adapter distinct from `implement-refactor`: do not perform behavior-preserving structural cleanup under this label. If the slice is refactoring-only, route to the `implement-refactor` port instead.

For the Halt-Return shape when a halt condition is reached, see `agents/Senior-Engineer.agent.md` § `## Halt-Return Contract`.

## Terminal credit step

At the terminal step, emit the `implement-code` credit row with the existing `Build-ImplementCodeCreditRow` builder. Do not modify the builder from this adapter.

Pass the repo-relative adapter path as the adapter evidence by setting `-AdapterName 'skills/implementation-discipline/adapters/implement-code-adapter.md'`, include validation evidence from the build-test cycle, and pass the terminal slice step number as `-Step {terminal-step-id}` for spine-backed terminal plans. Replace `{terminal-step-id}` with the numeric terminal slice step number.

When no spine terminal step is available because the plan legitimately uses `spine-omitted` legacy semantics, omit `-Step` and let the builder keep its default step value.

Example invocation shape:

```powershell
Build-ImplementCodeCreditRow `
  -AdapterName 'skills/implementation-discipline/adapters/implement-code-adapter.md' `
  -ValidationEvidence @(@{ Name = 'focused validation'; Status = 'passed' }) `
  -Evidence 'skills/implementation-discipline/adapters/implement-code-adapter.md executed with focused validation evidence.' `
  -Step {terminal-step-id}
```

Use the additive-merge rule for the PR-body `<!-- pipeline-metrics -->` block: if an `implement-code` credit row already exists for the same terminal step, leave it in place.
