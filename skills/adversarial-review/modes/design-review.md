<!-- markdownlint-disable-file MD041 MD003 -->

# Design Review Mode

Mode file for `design_plan_prosecution`. Loaded selector-conditionally alongside the shared core in [../SKILL.md](../SKILL.md) — see that file's § Mode-Scoped Loading. A dispatch in another mode must not load this file.

## Design Review

Use when the caller requests the design-review marker.

Review with these perspectives:

- Feasibility and Risk
- Scope and Completeness
- Integration and Impact

Each finding should cite the challenged decision, acceptance criterion, or scope element, and explain what breaks if the concern is real.

Output format:

```markdown
## Design Challenge Report

### §D1 — Feasibility & Risk

{findings or checked-no-issues summary}

### §D2 — Scope & Completeness

{findings or checked-no-issues summary}

### §D3 — Integration & Impact

{findings or checked-no-issues summary}

### Summary

{highest-risk items and overall confidence}
```
