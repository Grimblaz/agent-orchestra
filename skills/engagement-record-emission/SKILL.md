---
name: engagement-record-emission
description: "Marker contract for Segment-A maintainer-evidence and cross-session engagement-state preservation. Use when an agent exits its phase. DO NOT USE FOR: runtime code execution, test writing, or PR creation."
---

# Engagement Record Emission

This skill defines the `SMC-20` engagement-record marker contract and schema used to preserve agentic engagement state across sessions.

## When to Use

Use this skill when an upstream agent (Experience-Owner, Solution-Designer, or Issue-Planner) exits its respective phase. It provides a structured, durable way to record the decisions, classifications, and engineer choices made during the phase, allowing subsequent sessions or downstream agents to skip repetitive questioning on settled decisions.

## When Not to Use

Do not use this skill for runtime code execution, test writing, or PR creation. It is strictly a cognitive-evidence and state-preservation contract. Do not emit these markers in downstream phases. **Exception (v2 carve-out, #655 S3)**: the `review` phase is explicitly permitted to emit `<!-- engagement-record-review-{PR} -->` as a PR comment after the review judge verdict; this marker is PR-keyed (not issue-keyed) and governed by SMC-23.

## Marker Shape

Engagement records are emitted as GitHub issue comments containing a YAML code block wrapped inside a unique HTML comment marker representing the phase:

`<!-- engagement-record-{phase}-{ISSUE_ID_OR_PR} -->`

Where `{phase}` is one of `experience`, `design`, `plan` (at `schema_version: 2`), `orchestration` (at `schema_version: 3`, introduced in v1.3 / #577), or `review` (at `schema_version: 4`, introduced in #655 S3, PR-keyed); and `{ISSUE_ID_OR_PR}` is the GitHub issue ID (for experience/design/plan/orchestration phases) or PR number (for the `review` phase).

For example:
`<!-- engagement-record-design-575 -->`
`<!-- engagement-record-orchestration-577 -->`
`<!-- engagement-record-review-42 -->` (PR #42)

## Canonical Schema

The canonical YAML schema for the engagement-record payload is structured as follows:

```yaml
schema_version: 3
phase: orchestration                  # Valid values: experience | design | plan | orchestration | review
capture_session: "normal-orchestration-v3"  # Session tracking string
load_bearing_decisions:
  - decision_id: conductor-scope-classification  # Unique decision identifier
    classification: load-bearing      # Valid values: load-bearing | routine
    audit_rationale: "Rationale..."   # Short description of the why
    engineer_choice: "Choice..."      # Technical or design choice made
    teaching_paragraph_excerpt: "..." # Excerpt of the decision's context
    articulation_text: "..."          # Short paragraph detailing the engineer's rationale
    articulation_status: pending      # Valid values: pending | complete | incomplete
    recommendation_shift_trigger: engineer-pushback # Optional. Valid values: engineer-pushback | new-evidence | classification-re-audit | classification-re-audit-routine
```

## Persistence Rule

Multiple engagement-record markers may be written to the same issue for a given `(phase, issue)`. The latest-timestamp marker comment (based on GitHub comment `createdAt` field) wins on resume-read. This inherits the standard `SMC-08` / `SMC-17` latest-comment-wins convention.

## Schema Versioning Policy

Tooling that reads engagement records MUST throw an error on encountering an unknown `schema_version` value.
- **Additive-field policy**: Within a schema version, new optional fields may be added by writers. Readers MUST ignore unknown optional fields without throwing errors.
- **Breaking changes**: Any renamed fields, changed enum sets, or new required fields require incrementing the schema version. Readers built against v1.1 throw on v2 markers, and readers built against v1.2 throw on v3 markers — this is intentional; per #576 D4 and #577 D4 the helper is updated in lockstep and `.claude-plugin/plugin.json` is bumped to invalidate cached older readers. A backward-compatibility guard ensures that `phase: orchestration` requires `schema_version >= 3` to prevent reading orchestration markers with older schemas.

## Resume-Read Protocol

Downstream/upstream agents load engagement records at phase startup by calling the helper:
`Read-EngagementRecords -IssueNumber {ID} [-Phase experience|design|plan|orchestration|review] [-PullRequestNumber {PR}] [-InMemoryMarkers <string[]>] [-AcceptLegacy]`

If a record is returned for a given `decision_id`, the agent activates the `same-decision-resume` skip rule in `skills/solution-authoring/SKILL.md` to reuse the captured decision and suppress re-firing the structured question. For `review`-phase records, pass `-PullRequestNumber {PR}` instead of (or alongside) `-IssueNumber`. See SMC-23.

## articulation_status Transitions

- `pending`: Written by the authoring agent at phase exit.
- `complete` / `incomplete`: Written by the CE Gate evaluator after assessing the evidence.

> **Initial state**: writers SHOULD emit `articulation_text: ""` (empty string) paired with `articulation_status: pending` at phase exit. This is the documented initial state, not an error. The CE Gate (#578) closes the loop by evaluating and transitioning to `complete` or `incomplete`.

## Markdown Bullet ↔ YAML Key Map

Writers and validation tooling MUST enforce the following mapping when translating between the Markdown mirror's bullet fields and the YAML engagement-record's keys:

| Markdown Bullet Field | YAML Payload Key |
|---|---|
| `**Classification**` | `classification` |
| `**Engineer choice**` | `engineer_choice` |
| `**Audit rationale**` | `audit_rationale` |
| `**Decision brief excerpt**` | `teaching_paragraph_excerpt` |
| `**Articulation text**` | `articulation_text` |
| `**Articulation status**` | `articulation_status` |
| `**Recommendation shift trigger**` | `recommendation_shift_trigger` |

## Injection Policy

To prevent Markdown escaping and parsing errors on user-typed fields, writers MUST adhere to the following injection policy:
- Writers MUST use YAML block-scalar `|-` for all multi-line user-typed fields (`audit_rationale`, `articulation_text`, `engineer_choice`).
- Literal triple-backtick fence lines within those fields are strictly rejected at write time.

## capture_session Policy

The `capture_session` is a free-form string field that tracks the execution context. The recommended convention is:
`{trigger}-{phase}-v{major}[.{minor}]`
Where:
- `{trigger}` ∈ `normal` | `manual` | `replay`
- `{phase}` ∈ `experience` | `design` | `plan` | `orchestration` | `review`

Readers MUST NOT reject malformed values, but validation tooling may emit warnings on non-conforming strings.

## Related

- [session-memory-contract](../session-memory-contract/SKILL.md) (`SMC-20`)
- [solution-authoring](../solution-authoring/SKILL.md) (`same-decision-resume` skip rule)
- [frame-engagement-record-core](../../.github/scripts/lib/frame-engagement-record-core.ps1) (`Read-EngagementRecords` helper)
- **Note on Slug Disambiguation**: The customer-experience skill's prose use of "named decisions" refers to the same concept; engagement-record emission persists load-bearing classifications under the same unique slug namespace.

## Gotchas

| Trigger | Gotcha | Fix |
|---|---|---|
| Mismatched schema version | An older reader reads a v2 marker and crashes or drops decisions. | Enforce throwing on unknown schema_version and coordinate version bumps across all tools. |
| `-AcceptLegacy` cross-issue contamination | Before the MF2 fix, `-AcceptLegacy` bypassed the issue-number check, allowing markers from foreign issues to appear in results. | Never pass foreign-issue markers alongside `-AcceptLegacy`; the issue-number check is now always enforced. |
| Mixed-state issues | Issues that completed earlier phases pre-#576 and later phases post-#576 carry asymmetric resume coverage. | **`schema_version: 1` markers (from #575) ARE read by the helper** — `Read-EngagementRecords` accepts both v1 and v2 markers at parse time, so mixed-state issues with v1 design-phase markers and v2 plan-phase markers resume correctly across both phases. Only purely-pre-#571 markers (lacking `schema_version` entirely) require `-AcceptLegacy` to read; without that switch, they ARE opaque. |
| Comment-burst halt-on-failure | If engagement-record emission fails after the completion marker is posted, credit-input would still be posted. | Treat engagement-record post failure as a blocking error: halt the comment-burst, do NOT emit the credit-input marker, and log a warning to the terminal. |
| Markdown summary policy | Markdown bullet lists are human-readable mirrors of the YAML marker payload. | Automation tools must read only the YAML block; the Markdown bullets are for human review/audits only. |
| Articulation_text empty-window UX | `articulation_text: ""` renders as a blank bullet block in the human-readable Markdown section, which looks like an authoring error. | The Markdown mirror H3 sub-section in agent bodies appends the comment `<!-- CE Gate articulation pending per #578 -->` to clarify that evaluation has not yet occurred. |

## Frame Ports Filled By This Skill

None. This skill provides supporting methodology and specifications rather than a direct frame port.
