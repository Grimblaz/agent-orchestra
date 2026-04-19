---
name: ui-iteration
description: Reusable screenshot-driven UI polish workflow for iterative visual refinement. Use when improving layout, hierarchy, spacing, feedback, or Tailwind-based presentation through repeated review-and-adjust passes. DO NOT USE FOR: functional bug fixing, accessibility-only audits, or major redesign strategy work (use Code-Smith or frontend-design).
---

<!-- platform-assumptions: markdown skill guidance for VS Code custom agents in Copilot Orchestra; assumes the calling agent owns browser-tool applicability, invocation boundaries, and implementation handoff decisions. -->
<!-- markdownlint-disable-file MD041 MD003 -->

# UI Iteration

Reusable methodology for screenshot-based UI polish.

## When to Use

- When a page or component feels visually off but needs targeted refinement rather than redesign
- When repeated screenshot comparison is the fastest way to validate polish work
- When the work is mostly spacing, hierarchy, theme coherence, or interaction feedback
- When Tailwind or presentation-layer tweaks should be applied in bounded iterations

## Purpose

Improve the UI through short, measurable polish loops. Each pass should identify a small set of visual issues, apply focused changes, and confirm that the after state is visibly better than the before state.

## Iterative Polish Workflow

1. Capture a baseline screenshot of the target page or component state.
2. Assess the current UI against the evaluation criteria below.
3. Select 3-5 concrete improvements for the pass.
4. Implement the smallest set of presentation changes that address those issues.
5. Capture a follow-up screenshot.
6. Compare before and after, and record whether the pass produced measurable improvement.
7. Repeat until the planned iteration count is complete or additional changes stop producing clear gains.

## Screenshot Requirements

- Use a representative populated state rather than empty placeholders
- Prefer standard desktop browser width unless the task is explicitly mobile-first
- Keep captures focused on the target surface, not the full desktop
- Use programmatic screenshots when browser tools are available; otherwise follow the repo's fallback process

## Aesthetic Evaluation Criteria

### Generic UI Principles

| Principle        | What to Check                                   |
| ---------------- | ----------------------------------------------- |
| Readability      | Text contrast, font sizes, line height          |
| Visual Hierarchy | Clear focal points and emphasis                 |
| Spacing          | Consistent padding, margins, and breathing room |
| Alignment        | Grid alignment and edge consistency             |
| Consistency      | Similar elements styled similarly               |
| Feedback         | Hover, active, loading, and empty-state clarity |

### Product-Facing Checks

| Criterion           | What Good Looks Like                                        |
| ------------------- | ----------------------------------------------------------- |
| Information Clarity | Primary data and actions are obvious at a glance            |
| Theme Coherence     | Colors, typography, and surfaces feel intentionally related |
| Data Legibility     | Statuses, values, and labels remain easy to parse           |
| Motion Restraint    | Motion supports comprehension rather than distracting       |
| Pattern Benchmark   | New surfaces fit the product's established visual language  |

## Tailwind And UI Polish Heuristics

- Prefer design tokens and semantic utilities over arbitrary values
- Use spacing scales consistently before introducing custom exceptions
- Improve hierarchy with contrast, weight, grouping, and whitespace before adding more chrome
- Fix misalignment at the container or layout level before patching individual elements
- Keep motion subtle and purposeful
- Prefer utility composition over custom CSS when the design system already supports the need

## Iteration Parameters

| Parameter  | Default   | Typical Override Example                |
| ---------- | --------- | --------------------------------------- |
| Iterations | 5         | `Polish Dashboard 3 times`              |
| Scope      | Full page | `Polish just the SummaryCard component` |
| Focus      | All       | `Focus on spacing and alignment`        |

## Output Formats

### Per-Iteration Analysis

```markdown
## Iteration N/5 Analysis

**Target**: [Page/Component]

**Assessment**:

- ✅ [What is working]
- ⚠️ [Minor issues]
- ❌ [Significant issues]

**Proposed Improvements**:

1. [Specific change] - [Rationale]
2. [Specific change] - [Rationale]
3. [Specific change] - [Rationale]

**Files to Modify**:

- `src/...`
```

### Final Session Summary

```markdown
## UI Polish Complete

**Target**: [Page/Component]
**Iterations**: N/N

**Changes Made**:

1. [Change] (Iteration 1)
2. [Change] (Iteration 2)

**Before/After Summary**:

- Spacing: [Before] -> [After]
- Hierarchy: [Before] -> [After]
- Feedback: [Before] -> [After]

**Remaining Suggestions**:

- [Optional future polish]
```

## Related Guidance

- Load `frontend-design` when the polish work needs a stronger visual point of view
- Use browser-tool instructions from the current repo for navigation, startup, and cleanup details

## Gotchas

| Trigger                                     | Gotcha                                                      | Fix                                                            |
| ------------------------------------------- | ----------------------------------------------------------- | -------------------------------------------------------------- |
| The before and after screenshots look alike | The pass changed code without producing visible improvement | Reduce scope and choose 3-5 changes with clearer visual impact |

| Trigger                                    | Gotcha                                                 | Fix                                                              |
| ------------------------------------------ | ------------------------------------------------------ | ---------------------------------------------------------------- |
| Tailwind tweaks pile up element by element | The layout becomes inconsistent and harder to maintain | Fix spacing and alignment at the layout or container level first |
