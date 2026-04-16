---

name: implementation-discipline
description: Minimal implementation workflow for plan-driven coding. Use when preparing a small implementation slice, applying requirements-first coding discipline, or verifying that new code delegates instead of duplicating behavior. DO NOT USE FOR: test authoring strategy (use test-driven-development) or refactoring-only passes (use refactoring-methodology)
---

<!-- markdownlint-disable-file MD041 MD003 -->
<!-- platform-assumptions: markdown skill guidance for VS Code custom agents in Copilot Orchestra; assumes implementation work is plan-driven and validated in-repo. -->

# Implementation Discipline

Reusable implementation methodology for small, requirement-driven code changes.

## When to Use

- When implementing a bounded plan step or failing behavior slice
- When deciding how much code to add and how to keep the implementation minimal
- When checking whether new code should delegate to existing logic rather than duplicate it
- When validating implementation quality before handing off review or follow-up testing

## Purpose

Implement only what the requirements demand, with clear delegation boundaries and immediate validation. The goal is not to make tests green by any means necessary; it is to land the smallest correct implementation that satisfies the actual requirement.

## Pre-Implementation Review

1. Review the plan, design context, and local architecture constraints.
2. Confirm the intended change belongs in the current layer.
3. Outline the smallest implementation slice and likely files to touch.
4. Apply the replaceability test: if switching UI technology would change the code, it belongs outside core logic.

## Implementation Standards

- Do not add speculative features, helper methods, or abstractions without a current requirement
- Use straightforward names and keep control flow easy to inspect
- Prefer minimal changes over broad rewrites
- Extract helpers when complexity limits or readability clearly require it
- Follow repo architecture and file-size rules before adding new structure

## Requirements Verification

After implementing a slice, verify:

1. New components are wired into production code, not only tests.
2. Expected integration points are actually connected.
3. The implementation satisfies the design requirements and acceptance criteria.
4. Any JSON output created or edited is parseable and preserves required array typing.

If a requirement is missing from tests but clearly part of the requested behavior, implement it anyway and call out the missing coverage.

## Delegation Instead Of Duplication

When a new file or class needs logic that already exists:

1. Search for the existing formula, mapping, or validation first.
2. Inject the dependency and call it instead of copying behavior.
3. Use composition, strategies, or pipelines rather than parallel duplicate implementations.

Load `software-architecture` before extractions or new structural seams that affect layering or dependency direction.

## Verification Flow

1. Make the bounded implementation change.
2. Run the cheapest relevant validation for that slice.
3. Repair local defects before widening scope.
4. Only hand off once the implementation and validation agree with the requirement.

## Documentation And Markdown Hygiene

When implementation work edits permanent markdown files, run:

- `npx markdownlint-cli2 --fix "**/*.md" "!node_modules" "!.copilot-tracking" "!.copilot-tracking-archive"`

Then run the repository validation command required by the current task.

## Related Guidance

- Load `systematic-debugging` when the root cause is unclear
- Load `frontend-design` for intentional UI work
- Load `parallel-execution` when the current step explicitly runs in parallel mode

## Gotchas

| Trigger                                      | Gotcha                                                            | Fix                                                                 |
| -------------------------------------------- | ----------------------------------------------------------------- | ------------------------------------------------------------------- |
| Coding directly to satisfy a narrow assertion | Tests pass while the actual requirement or wiring remains missing | Re-check production wiring and design requirements before handoff    |

| Trigger                                   | Gotcha                                                           | Fix                                                                  |
| ----------------------------------------- | ---------------------------------------------------------------- | -------------------------------------------------------------------- |
| Copying logic into a new helper or class  | The change creates a second source of truth that drifts later    | Search first, inject the existing dependency, and delegate           |
