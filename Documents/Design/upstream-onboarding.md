# Design: Upstream Onboarding Skill (#481)

**Status**: Implemented — see `skills/upstream-onboarding/SKILL.md`
**Issue**: [#481](https://github.com/Grimblaz/agent-orchestra/issues/481)
**Date**: 2026-04-30

## Problem

The three upstream agents (Experience-Owner, Solution-Designer, Issue-Planner) shared no common opening behavior. Each agent activation was abrupt — no context brief, no standards check on inherited work. This led to three observable failure modes:

1. **Context gap**: Developers activating a new phase had to re-read the full issue history to orient themselves.
2. **Silent acceptance**: Agents inherited poorly-framed or standards-violating prior-phase output without challenge, compounding problems into planning and implementation.
3. **Redundant scaffolding**: Each agent body duplicated the same provenance-gate prose (three paragraphs + Questioning Policy heading), adding noise without value.

> **Update**: After this design landed, the `provenance-gate` skill itself was retired. The cold-pickup self-classification flow (the two-stage stop/proceed prompt) was found to be unintuitive in practice and its responsibilities were collapsed into `upstream-onboarding`. The historical references to `provenance-gate` in this design doc remain for context — they describe the original sequencing decision that has since been simplified.

## Design Decision

Introduce a single shared skill, `upstream-onboarding`, that user-invocable upstream agents (Experience-Owner, Solution-Designer, Issue-Planner) and Code-Conductor load when receiving an issue-referencing request. The skill has two responsibilities:

1. **Scaled context brief**: renders a brief oriented to the current phase's starting point — required core always present (one-line summary, scope tier, blocking questions), conditional sections (inherited decisions, standards concerns, constraints) omitted when empty.
2. **Standards check**: evaluates inherited work against the active agent's anchor standards, cites the specific violated standard by skill path + rule name, quotes the offending text, and presents a corrective approach as a structured question with a strong recommendation.

## Rejected Alternatives

### Shape 2: Per-Role Lens Files

Three separate `skills/upstream-onboarding/{experience-owner,solution-designer,issue-planner}.md` lens files loaded by each agent. Rejected because it duplicated the shared brief and trigger-rule logic across three files, and per-agent lens differences are small enough to live in one SKILL.md under a Per-Agent Lenses section.

### Shape 3: Inline in Each Agent Body

Embed the brief and standards check logic directly in each of the three agent bodies. Rejected because it would re-introduce the duplication problem the design was trying to solve, and any update to the shared logic would require three synchronized edits.

### Provenance-Gate Extension

Extend `provenance-gate` to carry the brief and standards check. Rejected at the time of this design because provenance-gate targeted a different artifact (issue framing on cold pickup by any agent, including Code-Conductor) at a different trigger condition. (Subsequent retirement of provenance-gate reversed this rejection by removing the gate entirely; `upstream-onboarding` now serves as the single opening-phase protocol regardless of whether the developer is cold-picking-up the issue or already briefed.)

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

## Relationship to `provenance-gate` (historical)

This design originally sequenced `upstream-onboarding` after `provenance-gate` on cold pickups, deferring to the gate's stop outcomes. After this design landed, the gate was retired (the two-stage cold-pickup self-classification was unintuitive in practice) and its responsibilities were collapsed into `upstream-onboarding`. The skill now serves as the single opening-phase protocol regardless of whether the developer is cold-picking-up the issue or already briefed; the brief is descriptive (no upfront question to answer), and the standards check uses targeted structured questions only when concerns actually fire.

## Resume Variant (#633)

Issue #633 extends the `upstream-onboarding` brief with a terse **resume variant** to cut the flow-break of opening GitHub at pickup and resume.

### Design Details

- **Trigger**: Same-agent resume (which previously skipped the brief entirely) now renders this resume-variant snapshot. The standards check is still skipped to prevent re-firing questions.
- **Content**: A terse ~4–6 line inline orientation snapshot assembled ONLY from already-loaded context to keep token cost bounded.
- **Field Mapping (D3)**:
  - **current phase** ⟵ latest phase marker (`<!-- plan-issue-{ID} -->`).
  - **last decision** ⟵ most recent `engagement-record-{phase}-{ID}` decisions.
  - **next step** ⟵ current plan position.
- **Missing-Record Fallback**: If no `engagement-record` exists on a real issue, the **last decision** field renders exactly `last decision: not recorded`.
- **On-Demand Expand (D4)**: Typing "expand" or "full picture" triggers the richer summary. This is handled in-turn as a context-local follow-up and is not suppressed by `/raw`.
- **Affordance-Hint Predicate (D5)**: A single-line hint appears below the snapshot only when a cheap check is true (≥1 engagement-record decision exists, or issue body materially exceeds the terse default snapshot size).
- **Code-Conductor smart-resume**: Independently authors and renders the same snapshot inline on marker detection.
- **Always-on risk (D7 watch item)**: Recorded the risk of the always-on snapshot becoming "wallpaper" and raising rubber-stamping; mitigated by keeping it strictly orientational.

## Relationship to Issue #375

Issue #375 introduces a lightweight scope tier for trivial changes. The `upstream-onboarding` brief scaling uses the `changeset.complexity` predicate as a forward-compatible hook: when #375 lands, its classifier wires into that predicate, automatically scaling the brief depth for trivial changes without any change to the `upstream-onboarding` skill itself. Issue #481 lands first; #375 builds on it.

## What Changed

- **New files**: `skills/upstream-onboarding/SKILL.md`, `skills/upstream-onboarding/platforms/claude.md`, `skills/upstream-onboarding/platforms/copilot.md`
- **Agent body edits**: `agents/Experience-Owner.agent.md`, `agents/Solution-Designer.agent.md`, `agents/Issue-Planner.agent.md` — duplicated provenance prose removed; `## Questioning Policy` heading removed from EO and SD; `upstream-onboarding` load reference added; Issue-Planner `## 3. Alignment` body trimmed to pointer
- **Shell updates**: `agents/experience-owner.md`, `agents/solution-designer.md` — `## Questioning Policy` token removed from section enumeration
- **Documentation**: `CLAUDE.md`, `skills/README.md`, this file
- **Version bump**: `.claude-plugin/plugin.json` per plugin-release-hygiene
