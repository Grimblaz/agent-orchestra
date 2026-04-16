---

name: research-methodology
description: Evidence-driven research methodology for technical analysis and recommendation building. Use when gathering verified findings, cross-referencing internal and external sources, or converging multiple options into one recommended approach. DO NOT USE FOR: implementation work (use implementation-discipline) or debugging a live failure path (use systematic-debugging)
---

<!-- markdownlint-disable-file MD041 MD003 -->
<!-- platform-assumptions: markdown skill guidance for VS Code custom agents in Copilot Orchestra; assumes evidence is gathered from workspace and approved external sources. -->

# Research Methodology

Reusable methodology for deep technical research that produces verified findings, clear trade-offs, and one recommended approach.

## When to Use

- When a task needs evidence-backed research before planning or implementation
- When findings must be cross-checked across multiple files, tools, or authoritative external sources
- When multiple viable approaches need a concise recommendation with explicit trade-offs
- When research notes need maintenance so stale or duplicate findings do not accumulate

## Purpose

Research should narrow uncertainty, not create more of it. Gather evidence, verify patterns across sources, document only what is supported by tools, and end with one recommended path that is ready for planning or implementation.

## Core Principles

- Treat unverified statements as hypotheses until tool output confirms them
- Prefer repeated evidence across independent sources over one-off matches
- Converge on one recommended approach instead of leaving unresolved option lists behind
- Delete superseded or duplicate findings as soon as better evidence appears
- Keep findings concise enough that a planner or implementer can act on them immediately

## Research Workflow

1. Define the research question and the specific decisions the research must support.
2. Gather internal evidence from the codebase, instructions, design docs, and neighboring implementations.
3. Add external evidence only when the workspace does not fully answer the question.
4. Compare viable approaches against project constraints, conventions, and maintenance cost.
5. Reduce alternatives to one recommended approach and remove discarded paths from the final notes.

## Evidence Collection

### Internal Research

- Read the closest owning files before broad exploration
- Search for repeated patterns, not isolated snippets
- Check usage sites to understand how a pattern is actually applied
- Verify repository conventions from architecture and instruction surfaces before recommending structural changes

### External Research

- Prefer official documentation, standards, or authoritative repositories
- Record why the source is relevant, not just what it says
- Cross-check external guidance against the repository's current constraints before treating it as applicable
- Stop external exploration once the remaining uncertainty no longer changes the recommendation

## Documentation Discipline

For each substantive finding:

1. Record the source or tool evidence that established it.
2. Explain the implementation or planning impact in one or two sentences.
3. Merge duplicate observations into one stronger entry.
4. Remove obsolete statements instead of stacking corrections under them.

## Alternative Analysis

When multiple approaches are viable, compare them on:

- Fit with current architecture and conventions
- Complexity to implement and validate
- Risk of drift or future maintenance cost
- Quality of supporting evidence in the codebase or authoritative sources

The final output should recommend one approach explicitly. Keep rejected alternatives out of the final research document unless they remain relevant as active risks or constraints.

## Completion Criteria

Research is complete when it can answer:

- What needs to change
- How it should be approached
- Where the work belongs in the repository
- Why the recommendation is preferable
- Which risks or unknowns still need explicit handling

If those questions are answered with verified evidence, stop researching and hand off.

## Handoff Expectations

- Provide the key discoveries that materially affect planning or implementation
- State one recommended approach, not an unranked list
- Call out unresolved risks or unavailable evidence explicitly
- Ensure the final notes are current, deduplicated, and ready for the next agent

## Related Guidance

- Load `implementation-discipline` when the work shifts from analysis to code changes
- Load `software-architecture` when the recommendation depends on dependency direction or layer boundaries
- Load `systematic-debugging` when the problem is a failing behavior with unclear root cause rather than an open-ended research question

## Gotchas

| Trigger                                               | Gotcha                                                                | Fix                                                               |
| ----------------------------------------------------- | --------------------------------------------------------------------- | ----------------------------------------------------------------- |
| Treating one matching file as proof of a repo pattern | A local exception is misreported as a convention                      | Verify the pattern across multiple owning files or call sites     |

| Trigger                                               | Gotcha                                                                | Fix                                                               |
| ----------------------------------------------------- | --------------------------------------------------------------------- | ----------------------------------------------------------------- |
| Leaving multiple viable approaches in the final notes | Planning stays ambiguous and downstream agents must redo the judgment | Choose one recommendation and delete superseded alternatives      |
