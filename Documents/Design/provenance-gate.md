# Design: First-Contact Provenance Gate

## Purpose

Prevent user-invocable pipeline agents from acting on an existing GitHub issue before the session has established whether the issue framing is trustworthy. On cold pickups, the gate forces a brief provenance check before work continues.

## Scope

The gate applies once per unique issue ID when a user-invocable agent receives an existing issue and no warm-handoff markers exist for that issue. Internal subagents skip the gate because they already run inside an assessed session.

## Current Flow

The shipped contract is a two-stage flow.

1. Stage 1 always runs first, before any assessment text appears.
2. If stage 1 returns `I wrote this / I'm fully briefed`, the agent takes the fast path and proceeds without showing the assessment summary.
3. If stage 1 returns `I'm picking this up cold`, the agent reads the issue, runs the three-question assessment, then asks the cold-only stage 2 decision.
4. If either stage returns a stop outcome, the agent stops and posts no provenance marker.

### Canonical Stage-1 Labels

- `I wrote this / I'm fully briefed`
- `I'm picking this up cold`
- `Stop — needs rework first`

### Canonical Stage-2 Labels

- `Assessment looks right — proceed`
- `Proceed but carry concerns forward`
- `Needs rework — stop here`

## Assessment Protocol

The cold path uses the shared three-question assessment from [skills/provenance-gate/SKILL.md](../../skills/provenance-gate/SKILL.md):

- Root cause vs. symptom
- Mechanism fitness
- Scope accuracy

The stage-2 `Proceed but carry concerns forward` outcome is a proceed path, not a stop path. The carried concerns remain visible in the conversation, but the durable marker semantics do not change.

## Durable Marker

Successful non-stop outcomes write a two-line durable marker:

```text
<!-- first-contact-assessed-{ID} -->
Provenance gate: fast-path or cold-path assessment completed; human-readable summary only.
```

Line 1 is the only skip-check anchor and the only parser anchor. Line 2 is human-readable and decorative only.

No stop outcome posts the marker token. That includes both `Stop — needs rework first` and `Needs rework — stop here`.

## Persistence And Offline Recovery

Primary persistence is the GitHub issue comment marker, and that GitHub marker is the durable source of truth. The session-memory fallback payload is a best-effort local recovery aid, not a durable substitute. If GitHub lookup or posting is unavailable, the gate fails open visibly:

- the developer is told offline mode is active
- a structured payload is written to `/memories/session/first-contact-assessed-{ID}.md`
- if the next online invocation finds the GitHub marker still missing and the local fallback payload is still available, it reconstructs the two-line GitHub marker, posts it, and clears the local fallback state

If that local fallback payload is no longer available, there is no local state left to replay; recovery then depends on the GitHub marker already existing.

The local fallback payload keeps the current outcome contract: `fast-path`, `proceeded`, or `proceeded with concerns`.

## Warm-Handoff And Multi-Issue Behavior

The gate skips entirely when any warm-handoff marker already exists for the issue, including `plan-issue-{ID}`, `design-issue-{ID}`, `<!-- experience-owner-complete-{ID} -->`, or `<!-- design-phase-complete-{ID} -->`.

In multi-issue bundles, the gate runs once per unique issue ID rather than once per user message.

## Current Sources Of Truth

- [skills/provenance-gate/SKILL.md](../../skills/provenance-gate/SKILL.md) - shared provenance-gate contract
- [skills/provenance-gate/platforms/copilot.md](../../skills/provenance-gate/platforms/copilot.md) - Copilot presentation details
- [skills/provenance-gate/platforms/claude.md](../../skills/provenance-gate/platforms/claude.md) - Claude presentation details
- [.github/scripts/Tests/provenance-gate.Tests.ps1](../../.github/scripts/Tests/provenance-gate.Tests.ps1) - contract coverage for labels, marker shape, and offline fallback behavior
- [.github/scripts/Tests/handoff-persistence-contract.Tests.ps1](../../.github/scripts/Tests/handoff-persistence-contract.Tests.ps1) - persistence and marker consistency checks
