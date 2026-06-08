---
name: implement-docs-adapter
provides: implement-docs
adapter-type: work
description: "Work adapter for documentation-authoring slices executed by Senior Engineer"
---

<!-- markdownlint-disable-file MD041 -->

## When to use

### Pick this when

- The frame slice asks for documentation work for the `implement-docs` port.
- The changeset introduces new production behavior, a new interface contract, or a changed integration point that requires corresponding documentation updates.
- User-facing, operator-facing, or maintainer-facing docs must be updated to reflect behavior that was just implemented in a preceding `implement-code` slice.
- Skill, adapter, or agent body documentation must be authored or revised to reflect the current slice's changes.

### Don't pick this when

- The slice is for production implementation, test authoring, refactoring-only cleanup, UI polish, specification writing, or adversarial review; route those to their own ports.
- The changeset has no behavior or interface change that affects documentation (e.g., internal refactor with no externally observable effect); route that case to `skills/documentation-finalization/adapters/implement-docs-auto-na-adapter.md`.
- The documentation to be authored would require inventing interface contracts or behavior that are not established by the plan or prior slices.

## Execution contract

Apply `skills/documentation-finalization/SKILL.md` to the behavior and interface changes introduced by the current slice. Update or author documentation that reflects what the production code now does; do not speculate about future states or document behavior that the current changeset does not establish.

Keep this adapter distinct from `implement-code`: do not add or modify production behavior under a documentation label. If a production or interface gap must be closed before accurate documentation can be written, halt with `scope-violation` and return the slice to the conductor for the appropriate port.

Use the skill's analysis workflow, mandatory checks, and output structure as the authority for execution details; this adapter only binds that methodology to the `implement-docs` port and terminal credit step.

At the terminal credit step, emit the `implement-docs` credit row with the existing `Build-ImplementDocsCreditRow` builder. This adapter authors the instruction only; do not invoke the builder while creating or editing this file.

Pass the repo-relative adapter path as adapter evidence by setting `-AdapterName 'skills/documentation-finalization/adapters/implement-docs-adapter.md'`, include validation evidence from the documentation review cycle with `-ValidationEvidence`, include a concise execution summary with `-Evidence`, and pass the terminal slice step number with `-Step`. In the example below, replace `{terminal-step-id}` with that numeric terminal slice step number.

Example invocation shape:

```powershell
Build-ImplementDocsCreditRow `
  -AdapterName 'skills/documentation-finalization/adapters/implement-docs-adapter.md' `
  -ValidationEvidence @(@{ Name = 'focused docs validation'; Status = 'passed' }) `
  -Evidence 'skills/documentation-finalization/adapters/implement-docs-adapter.md executed with documentation-authoring validation evidence.' `
  -Step {terminal-step-id}
```

Use the additive-merge rule for the PR-body `<!-- pipeline-metrics -->` block: if an `implement-docs` credit row already exists for the same terminal step, leave it in place.
