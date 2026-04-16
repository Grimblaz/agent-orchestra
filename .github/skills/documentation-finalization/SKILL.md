---

name: documentation-finalization
description: Documentation finalization workflow for accuracy, cleanup, and design-doc maintenance. Use when updating implementation-facing docs, synchronizing design documents with shipped behavior, or removing obsolete documentation. DO NOT USE FOR: formal specification drafting (use specification-authoring) or source-code implementation decisions (use implementation-discipline)
---

<!-- markdownlint-disable-file MD041 MD003 -->
<!-- platform-assumptions: markdown skill guidance for VS Code custom agents in Copilot Orchestra; applies to repository documentation and agent markdown updates. -->

# Documentation Finalization

Reusable documentation-finalization process for implementation and design updates.

## When to Use

- When implementation changed names, behavior, file paths, or architecture references in docs
- When a design document in `Documents/Design/` must be created or updated for the current domain
- When obsolete placeholders, duplicate guidance, or stale references must be removed before completion
- When documentation work needs a consistent finalization checklist rather than ad hoc edits

## Purpose

Make documentation reflect the shipped state of the repository. Treat deletion of stale content as first-class work, and verify every technical statement against implementation before leaving the documentation phase.

## Documentation Areas

### Development Docs

- Update current-state, setup, architecture, and workflow documents to match the implementation
- Replace outdated file paths, names, timelines, and phase markers
- Remove "not yet implemented" language once behavior exists

### Design Docs

- Keep terminology aligned with actual classes, methods, scripts, headings, and behaviors
- Refresh examples, formulas, schemas, and interaction descriptions to match current behavior
- Remove placeholders such as `TBD`, `coming soon`, or obsolete alternative designs

### Decision Docs

- Update existing ADRs when a shipped decision changed
- Create or refine decision records only when implementation introduced or documented an actual decision
- Remove obsolete decision records only when a newer source of truth fully supersedes them

### Domain Design Docs

- Prefer updating an existing domain file when the feature extends an established design area
- Create a new `Documents/Design/{domain-slug}.md` file only when no current domain doc covers the feature area
- Keep domain docs focused on the current design state, not as per-issue changelogs

## Finalization Workflow

1. Review the relevant implementation and determine what actually changed.
2. Update the affected development and design documents to match shipped behavior.
3. Apply any required decision-record updates tied to real implementation decisions.
4. Remove obsolete content, duplicate guidance, and placeholder text.
5. Verify terminology, file paths, cross-references, and examples against the codebase.
6. Run markdown formatting and repo validation before handing off completion.

## Quality Checks

- Match code names, signatures, entity names, and workflow labels exactly
- Verify file paths, section cross-references, and command examples still exist
- Remove stale future-tense statements once the work shipped
- Prefer consolidation over duplication when multiple docs describe the same rule
- For domain design docs, describe the stable domain behavior rather than issue-by-issue history

## Conciseness Guidelines

- Target roughly 150-250 lines per permanent document when practical
- Split a document when it serves multiple unrelated purposes or becomes hard to navigate
- Prefer linking to the authoritative doc instead of restating the same guidance in multiple places
- Value deletion as much as addition when reducing confusion

## Validation

- Run `markdownlint-cli2 --fix "**/*.md"`
- Run `pwsh -NoProfile -NonInteractive -File .github/scripts/quick-validate.ps1`
- When agent markdown is edited, confirm the `tools:` frontmatter still matches the capabilities described in the body

## Gotchas

| Trigger                                       | Gotcha                                                             | Fix                                                                 |
| --------------------------------------------- | ------------------------------------------------------------------ | ------------------------------------------------------------------- |
| Updating docs from intent instead of code     | Documentation drifts toward the plan rather than the shipped state | Verify names, paths, and behavior against the current implementation |

| Trigger                                      | Gotcha                                                            | Fix                                                          |
| -------------------------------------------- | ----------------------------------------------------------------- | ------------------------------------------------------------ |
| Turning a domain design doc into issue notes | The file becomes a changelog and stops reflecting the current UX  | Rewrite the doc around current domain behavior and delete drift |
