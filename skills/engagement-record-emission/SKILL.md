---
name: engagement-record-emission
description: "Marker contract for Segment-A maintainer-evidence and cross-session engagement-state preservation. Use when an agent exits its phase. DO NOT USE FOR: runtime code execution, test writing, or PR creation."
---

# Engagement Record Emission

This skill defines the `SMC-20` engagement-record marker contract and schema used to preserve agentic engagement state across sessions.

## When to Use

Use this skill when an upstream agent (Experience-Owner, Solution-Designer, or Issue-Planner) exits its respective phase. It provides a structured, durable way to record the decisions, classifications, and engineer choices made during the phase, allowing subsequent sessions or downstream agents to skip repetitive questioning on settled decisions.

## When Not to Use

Do not use this skill for runtime code execution, test writing, or PR creation. It is strictly a cognitive-evidence and state-preservation contract. Do not emit these markers in downstream or PR-level review phases.

## Marker Shape

Engagement records are emitted as GitHub issue comments containing a YAML code block wrapped inside a unique HTML comment marker representing the phase:

`<!-- engagement-record-{phase}-{ISSUE_ID} -->`

Where `{phase}` is one of `experience` or `design` (for v1.1; the `plan` phase is deferred to a later release), and `{ISSUE_ID}` is the numerical GitHub issue ID.

For example:
`<!-- engagement-record-design-575 -->`

## Canonical Schema

The canonical YAML schema for the engagement-record payload is structured as follows:

```yaml
schema_version: 1
phase: design                         # Valid values: experience | design
capture_session: "normal-design-v1"  # Session tracking string
load_bearing_decisions:
  - decision_id: schema-location      # Unique decision identifier
    classification: load-bearing      # Valid values: load-bearing | routine
    audit_rationale: "Rationale..."   # Short description of the why
    engineer_choice: "Choice..."      # Technical or design choice made
    teaching_paragraph_excerpt: "..." # Excerpt of the decision's context
    articulation_text: "..."          # Short paragraph detailing the engineer's rationale
    articulation_status: pending      # Valid values: pending | complete | incomplete
```

## Persistence Rule

Multiple engagement-record markers may be written to the same issue for a given `(phase, issue)`. The latest-timestamp marker comment (based on GitHub comment `createdAt` field) wins on resume-read. This inherits the standard `SMC-08` / `SMC-17` latest-comment-wins convention.

## Schema Versioning Policy

Tooling that reads engagement records MUST throw an error on encountering an unknown `schema_version` value.
- **Additive-field policy**: Within `schema_version: 1`, new optional fields may be added by writers. Readers MUST ignore unknown optional fields without throwing errors.
- **Breaking changes**: Any renamed fields, changed enum sets, or new required fields require incrementing to `schema_version: 2`.

## Resume-Read Protocol

Downstream/upstream agents load engagement records at phase startup by calling the helper:
`Read-EngagementRecords -IssueNumber {ID} [-Phase experience|design] [-InMemoryMarkers] [-AcceptLegacy]`

If a record is returned for a given `decision_id`, the agent activates the `same-decision-resume` skip rule in `skills/solution-authoring/SKILL.md` to reuse the captured decision and suppress re-firing the structured question.

## articulation_status Transitions

- `pending`: Written by the authoring agent at phase exit.
- `complete` / `incomplete`: Written by the CE Gate evaluator after assessing the evidence.

> **Initial state**: writers SHOULD emit `articulation_text: ""` (empty string) paired with `articulation_status: pending` at phase exit. This is the documented initial state, not an error. The CE Gate (#578) closes the loop by evaluating and transitioning to `complete` or `incomplete`.

## capture_session Policy

The `capture_session` is a free-form string field that tracks the execution context. The recommended convention is:
`{trigger}-{phase}-v{major}[.{minor}]`
Where:
- `{trigger}` ∈ `normal` | `manual` | `replay`
- `{phase}` ∈ `experience` | `design` | `plan`

Readers MUST NOT reject malformed values, but validation tooling may emit warnings on non-conforming strings.

## Related

- [session-memory-contract](../session-memory-contract/SKILL.md) (`SMC-20`)
- [solution-authoring](../solution-authoring/SKILL.md) (`same-decision-resume` skip rule)
- [frame-engagement-record-core](../../.github/scripts/lib/frame-engagement-record-core.ps1) (`Read-EngagementRecords` helper)

## Gotchas

| Trigger | Gotcha | Fix |
|---|---|---|
| Mismatched schema version | An older reader reads a v2 marker and crashes or drops decisions. | Enforce throwing on unknown schema_version and coordinate version bumps across all tools. |
| `-AcceptLegacy` cross-issue contamination | Before the MF2 fix, `-AcceptLegacy` bypassed the issue-number check, allowing markers from foreign issues to appear in results. | Never pass foreign-issue markers alongside `-AcceptLegacy`; the issue-number check is now always enforced. |
| v1.1 / #576 emission gap | The read path (`Read-EngagementRecords`) is live; the write path (agents emitting markers) is deferred to #576. Downstream consumers should tolerate missing markers gracefully. | Treat absent records as empty; do not hard-fail when no marker exists for a phase. |

## Frame Ports Filled By This Skill

None. This skill provides supporting methodology and specifications rather than a direct frame port.
