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

Run the smallest correct implementation that satisfies the dispatched requirement. Treat tests as evidence, not as the requirement itself: making a narrow assertion pass is insufficient when production wiring, integration points, or design acceptance criteria remain unmet.

Use these coding principles while executing the slice:

- Requirements over tests: implement the documented behavior even when current tests cover only part of it.
- YAGNI: do not add speculative options, helpers, abstractions, configuration, or future-facing behavior.
- Minimal change: prefer a direct local edit over a broad rewrite when both satisfy the requirement.
- Layer boundaries: keep core behavior out of UI, shell, or runtime glue unless the requirement explicitly belongs there.
- Scope discipline: leave adjacent cleanup and follow-up ideas out of the implementation unless they are required for correctness.
- Delegation over duplication: search for existing formulas, validation, mapping, and serialization before adding new logic.

## Pre-implementation review

Before editing files:

1. Read the frame slice, plan requirement contract, relevant design context, and any cited acceptance criteria.
2. Identify the production behavior that must change and the expected validation evidence.
3. Confirm the change belongs in the current layer. Apply the replaceability test: if changing UI technology would change this code, it should not live in core logic.
4. Search the local area for existing behavior that should be reused instead of copied.
5. Name the smallest file set likely to satisfy the requirement. If the slice requires unrelated files, halt with `scope-violation`.

## Implementation discipline

- Implement only the current slice. Do not pre-build later plan steps.
- Keep names straightforward and control flow easy to inspect.
- Extract a helper only when it removes real duplication or keeps required logic readable.
- Prefer structured APIs and serializers over manual string construction for structured data.
- Preserve required array typing and parseability when editing JSON or JSON-like output.
- Keep existing user or agent changes intact; work with them when they affect the slice.

If the implementation would need a new architectural seam, substantial refactor, or cross-layer dependency not called for by the plan, halt with `simplicity-violation` or `scope-violation` and cite the exact requirement conflict.

```yaml
halt_return:
  halt_reason: simplicity-violation
  adapter_path: "skills/implementation-discipline/adapters/implement-code-adapter.md"
  slice_id: "s3"
  summary: "The requested implementation requires a new framework adapter that is not part of this slice."
  evidence:
    - "The slice only authorizes the implement-code port for the current production behavior."
    - "The proposed change would introduce a cross-layer dependency before the design documents that seam."
  recommended_next_owner: "planner"
```

## Bad test and blocked-input handling

Stop implementation when a failing or newly added test appears wrong instead of exposing a product gap. Bad-test signals include incorrect expectations, assertions on implementation details, mismatch with documented requirements, invalid setup, or multiple failures sharing a likely test-side root cause.

Do not edit the test, distort production code to satisfy it, or continue as if the requirement is clear. Return a halt finding with concrete evidence.

```yaml
halt_return:
  halt_reason: push-back
  adapter_path: "skills/implementation-discipline/adapters/implement-code-adapter.md"
  slice_id: "s3"
  summary: "The blocking test expects behavior that conflicts with the accepted requirement."
  evidence:
    - "Requirement AC5 states the work adapter must omit applies-when."
    - "The failing assertion requires applies-when to be present on every adapter file."
  recommended_next_owner: "test writer"
```

Use `uncertainty` when the slice lacks required inputs, `confusion` when inputs conflict, and `verification-gap` when required evidence cannot be produced after implementation.

## Requirements verification

After editing:

1. Confirm the new behavior is wired into production code, not only test fixtures.
2. Confirm expected integration points are connected.
3. Compare the implementation against the design requirements and acceptance criteria.
4. Validate structured output with the relevant parser when you create or edit it.
5. Run the cheapest relevant validation command for the slice, then widen only if the plan requires it.
6. If a documented requirement is not covered by tests, implement it anyway and report the missing coverage in the completion evidence.

Completion evidence must name the changed files, the validation commands, pass/fail counts when available, and any requirement coverage that relied on manual inspection.

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
