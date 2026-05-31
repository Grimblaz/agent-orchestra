---
name: implement-refactor-adapter
provides: implement-refactor
adapter-type: work
description: "Work adapter for behavior-preserving refactoring slices executed by Senior Engineer"
---

<!-- markdownlint-disable-file MD041 -->

## When to use

### Pick this when

- The frame slice asks for behavior-preserving refactoring work for the `implement-refactor` port.
- The changeset has refactorable debt in touched files or immediate neighbors, above the threshold for a behavior-preserving cleanup: real maintainability debt, duplication, oversized units, unclear naming, or local integration gaps that can be improved without changing behavior.
- The refactor can stay within the files already modified by the current work or their immediate neighbors.
- Existing validation can show that behavior remains unchanged after the structural improvement.

### Don't pick this when

- The slice asks for net-new production behavior, test authoring, documentation, UI polish, specification writing, or adversarial review.
- The changeset has no qualifying refactorable debt in touched files or immediate neighbors, or the debt is below the threshold for a behavior-preserving cleanup; route that case to `skills/refactoring-methodology/adapters/implement-refactor-auto-na-adapter.md`.
- The requested cleanup would require broad rewrites, public API reshaping, unrelated file moves, cross-cutting abstractions, or architecture decisions beyond the current slice.
- The work would change observable behavior instead of preserving behavior while improving structure.

## Execution contract

Apply `skills/refactoring-methodology/SKILL.md` to the touched files and immediate neighbors named by the slice. Preserve behavior while improving structure that is already in scope: remove duplication, extract local helpers when they reduce real complexity, improve unclear names, simplify awkward conditionals, and connect local integration gaps that make the current change incomplete.

Keep this adapter distinct from `implement-code`: do not add product behavior, new feature sections, or future-facing options under a refactor label. If implementation behavior must change before the refactor makes sense, halt with `scope-violation` and return the slice to the conductor for the appropriate port.

Use the skill's analysis workflow, mandatory checks, and output structure as the authority for execution details; this adapter only binds that methodology to the `implement-refactor` port and terminal credit step.

At the terminal credit step, emit the `implement-refactor` credit row with the existing `Build-ImplementRefactorCreditRow` builder. This adapter authors the instruction only; do not invoke the builder while creating or editing this file.

Pass the repo-relative adapter path as adapter evidence by setting `-AdapterName 'skills/refactoring-methodology/adapters/implement-refactor-adapter.md'`, include validation evidence from the refactor validation cycle with `-ValidationEvidence`, include a concise execution summary with `-Evidence`, and pass the terminal slice step number with `-Step`. In the example below, replace `<terminal-step-id>` with that numeric terminal slice step number.

Example invocation shape:

```powershell
Build-ImplementRefactorCreditRow `
  -AdapterName 'skills/refactoring-methodology/adapters/implement-refactor-adapter.md' `
  -ValidationEvidence @(@{ Name = 'focused refactor validation'; Status = 'passed' }) `
  -Evidence 'skills/refactoring-methodology/adapters/implement-refactor-adapter.md executed with behavior-preserving validation evidence.' `
  -Step <terminal-step-id>
```

Use the additive-merge rule for the PR-body `<!-- pipeline-metrics -->` block: if an `implement-refactor` credit row already exists for the same terminal step, leave it in place.
