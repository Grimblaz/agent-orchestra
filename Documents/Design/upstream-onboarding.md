# Design: Upstream Onboarding Skill (#481)

**Status**: Implemented — see `skills/upstream-onboarding/SKILL.md`
**Issue**: [#481](https://github.com/Grimblaz/agent-orchestra/issues/481)
**Date**: 2026-04-30

## Problem

The three upstream agents (Experience-Owner, Solution-Designer, Issue-Planner) shared no common opening behavior. Each agent activation was abrupt — no context brief, no standards check on inherited work. This led to three observable failure modes:

1. **Context gap**: Developers activating a new phase had to re-read the full issue history to orient themselves.
2. **Silent acceptance**: Agents inherited poorly-framed or standards-violating prior-phase output without challenge, compounding problems into planning and implementation.
3. **Redundant scaffolding**: Each agent body duplicated the same provenance-gate prose (three paragraphs + Questioning Policy heading), adding noise without value.

## Design Decision

Introduce a single shared skill, `upstream-onboarding`, that all three upstream agents load after `provenance-gate` completes a non-stop outcome. The skill has two responsibilities:

1. **Scaled context brief**: renders a brief oriented to the current phase's starting point — required core always present (one-line summary, scope tier, blocking questions), conditional sections (inherited decisions, standards concerns, constraints) omitted when empty.
2. **Standards check**: evaluates inherited work against the active agent's anchor standards, cites the specific violated standard by skill path + rule name, quotes the offending text, and presents a corrective approach as a structured question with a strong recommendation.

## Rejected Alternatives

### Shape 2: Per-Role Lens Files

Three separate `skills/upstream-onboarding/{experience-owner,solution-designer,issue-planner}.md` lens files loaded by each agent. Rejected because it duplicated the shared brief and trigger-rule logic across three files, and per-agent lens differences are small enough to live in one SKILL.md under a Per-Agent Lenses section.

### Shape 3: Inline in Each Agent Body

Embed the brief and standards check logic directly in each of the three agent bodies. Rejected because it would re-introduce the duplication problem the design was trying to solve, and any update to the shared logic would require three synchronized edits.

### Provenance-Gate Extension

Extend `provenance-gate` to carry the brief and standards check. Rejected because provenance-gate targets a different artifact (issue framing on cold pickup by any agent, including Code-Conductor) at a different trigger condition. Conflating the two would widen provenance-gate's scope inappropriately and make it harder to skip for agents that don't need it.

### Hard Cap on Questions

Impose a numeric cap (e.g., ≤ 3) on standards-check questions per activation. Rejected because the right boundary is judgment-based (certainty × risk), not a fixed count. A well-founded concern at index 4 must still be raised; a low-confidence concern at index 1 should be held. A hard cap would suppress legitimate concerns and encourage padding low-quality ones to fill the budget.

### Fixed Template

Require a fixed five-bullet brief regardless of change complexity. Rejected because it produces noise for trivial changes (a one-file rename rendered with five bullets) and is too terse for major architectural changes. The scaled brief (required core + conditional sections by `changeset.complexity`) adapts without over-specifying.

## Per-Agent Lens Contract

Each upstream agent applies the standards check through its own lens. The lenses are defined in `skills/upstream-onboarding/SKILL.md` under `## Per-Agent Lenses` and are summarized here for discoverability:

| Agent | Standards Anchors | Key Concern Triggers |
| --- | --- | --- |
| Experience-Owner | `customer-experience`, `bdd-scenarios` | Solution-shaped problem statement, missing intent scenario, unclassified surface, non-customer-language scenario clauses |
| Solution-Designer | `design-exploration`, `software-architecture`, consumer `architecture-rules.md` | Single prescription without alternatives, layer boundary violation, missing rejected alternatives |
| Issue-Planner | `plan-authoring`, `tracking-format` | Step without AC slice, CE Gate gap, missing Requirement Contract, scope mismatch |

## Relationship to `provenance-gate`

`provenance-gate` and `upstream-onboarding` serve different trigger conditions and target different artifacts:

| | `provenance-gate` | `upstream-onboarding` |
| --- | --- | --- |
| **Fires when** | Any cold pickup by any user-invocable agent | Prior phase completed by a *different* upstream agent |
| **Artifact checked** | Issue framing accuracy (root cause, mechanism fitness, scope accuracy) | Prior agent's output against the current agent's standards |
| **Outcome on stop** | Halts; no marker posted | Does not fire (provenance-gate already halted) |
| **Skip condition** | Warm handoff markers or prior assessment marker present | Same-agent resume (own marker is most recent) |

`upstream-onboarding` defers to provenance-gate's stop outcomes. On a non-stop outcome, `upstream-onboarding` fires next and focuses on what the prior upstream phase produced.

## Relationship to Issue #375

Issue #375 introduces a lightweight scope tier for trivial changes. The `upstream-onboarding` brief scaling uses the `changeset.complexity` predicate as a forward-compatible hook: when #375 lands, its classifier wires into that predicate, automatically scaling the brief depth for trivial changes without any change to the `upstream-onboarding` skill itself. Issue #481 lands first; #375 builds on it.

## What Changed

- **New files**: `skills/upstream-onboarding/SKILL.md`, `skills/upstream-onboarding/platforms/claude.md`, `skills/upstream-onboarding/platforms/copilot.md`
- **Agent body edits**: `agents/Experience-Owner.agent.md`, `agents/Solution-Designer.agent.md`, `agents/Issue-Planner.agent.md` — duplicated provenance prose removed; `## Questioning Policy` heading removed from EO and SD; `upstream-onboarding` load reference added; Issue-Planner `## 3. Alignment` body trimmed to pointer
- **Shell updates**: `agents/experience-owner.md`, `agents/solution-designer.md` — `## Questioning Policy` token removed from section enumeration
- **Documentation**: `CLAUDE.md`, `skills/README.md`, this file
- **Version bump**: `.claude-plugin/plugin.json` per plugin-release-hygiene
