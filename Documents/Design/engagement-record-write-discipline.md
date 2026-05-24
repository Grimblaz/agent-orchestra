# Design: Named Decisions Write-Discipline & Engagement-Record Emission

**Domain**: Upstream Pipeline State Preservation & Cognitive-Surrender Prevention  
**Status**: Current  
**Implemented in**: Issue #576  

---

## Purpose

This document records the design rationale for the **Named Decisions write-discipline and engagement-record emission** for the upstream pipeline phases (`/experience`, `/design`, and `/plan`). It details the methodology, decisions, and verification mechanisms implemented to guarantee that cross-session engagement state is preserved robustly and durably.

The canonical operational schema lives in [skills/engagement-record-emission/SKILL.md](../../skills/engagement-record-emission/SKILL.md).

## Problem

Upstream agents (Experience-Owner, Solution-Designer, and Issue-Planner) frequently make critical architectural and design choices. Previously, these choices were either lost between sessions or required tedious, repetitive user questioning upon phase re-entry (cognitive surrender). While `Read-EngagementRecords` existed to resume state, there was no structured, standardized, or verified way to emit these markers across all upstream agents.

Additionally, slug formats were loose, allowing arbitrary characters that broke downstream parsing. A strict, TDD-enforced, and byte-equivalent discipline was needed to ensure all upstream agents emit identical, valid metadata.

## Options Considered

| Option | Summary | Decision |
| --- | --- | --- |
| A | Implement inline write-discipline directly inside each upstream agent body with locked structures. | Selected |
| B | Outsource marker writing to a centralized helper script invoked by agents. | Rejected (Agents need inline execution rules to guide LLM behavior directly) |
| C | Rely on downstream Code-Conductor to infer and write the upstream markers. | Rejected (Violates the single-responsibility principle and introduces timing hazards) |

## Why Option A Won

Upstream agents operate via natural-language reasoning and markdown editing. Hardcoding the **Named Decisions write-discipline** block directly inside the agent system instructions (`.agent.md`) forces the LLM to follow the precise 3-comment burst ordering, size limits, and block-scalar rules. 

Centralized scripts (Option B) are excellent for parsing but fail to govern the LLM's raw cognitive formatting. Downstream inference (Option C) would introduce massive synchronization hazards, as Code-Conductor cannot reliably reconstruct the reasoning of a prior phase without the original agent's direct emission.

## Design Decisions

### D1 - High-Integrity Dual Representation (Markdown Mirror & YAML Block)

Every named decision is written in two places during completion:
1. A human-readable Markdown section (`## Named Decisions` or within plan comments) enclosed in `<!-- named-decisions:begin -->` ... `<!-- named-decisions:end -->` sentinels.
2. A machine-readable YAML engagement-record comment (`<!-- engagement-record-{phase}-{ID} -->`) containing exact duplicates of the decision fields.

This provides maximum transparency for human audits while allowing fast, deterministic parsing by tooling.

### D2 - Byte-Equivalent Instruction Injection

To guarantee that all upstream agents are trained on the exact same formatting discipline, their respective `.agent.md` files carry a **byte-equivalent** sub-section titled `### Named Decisions write-discipline`. This section is identical across Experience-Owner, Solution-Designer, and Issue-Planner after basic placeholder normalization.

### D3 - Strict Slug Validation (`Test-EngagementRecordSlug`)

Slugs must strictly match the regex `^[a-z][a-z0-9-]{1,63}$` and cannot end with a hyphen. The helper `Test-EngagementRecordSlug` enforces this at the core library level, and any non-legacy parser run throws an immediate, standardized exception if an invalid slug is encountered.

### D4 - Multi-Line Injection Policy

To prevent YAML parsing failures, all multi-line user-typed fields (`audit_rationale`, `articulation_text`, `engineer_choice`) MUST use the YAML block-scalar chomping indicator `|-`. Literal triple-backticks within these fields are strictly rejected.

### D5 - Same-Decision-Resume Integration (`MF5`)

At startup, agents load prior engagement records using `Read-EngagementRecords`. If a matching decision is found with classification `load-bearing`, the agent suppresses the interactive question branch, reuses the prior choice, and proceeds. This closes the loop on cognitive-surrender prevention.

### D6 - Comment-Burst Ordering (Standardized Across Phases)

Phase exit emits a unified 3-comment burst, in strict order:

1. `<!-- {phase}-complete-{ID} -->` — the phase-completion marker (existing).
2. `<!-- engagement-record-{phase}-{ID} -->` — the engagement-record marker (new in #576).
3. `<!-- credit-input-{phase}-{ID} -->` — the deferred-emission marker harvested by Code-Conductor at PR creation.

The agent-body wording was standardized so Experience-Owner, Solution-Designer, and Issue-Planner share the same "post completion marker; then engagement-record; then credit-input" instruction. Issue-Planner additionally posts the `<!-- plan-issue-{ID} -->` comment first, then the same 3-comment burst.

**Failure handling**: if engagement-record emission fails after the completion marker is posted, the agent surfaces a `⚠️ Engagement-record emission failed for {phase}-{ID}: {reason}` warning. The phase is still marked complete, but `same-decision-resume` on the next session returns empty and degrades to v1.1 behavior. The `credit-input` marker is **not** emitted in this failure path. This contract is mirrored in the SKILL.md gotchas table.

### D7 - Plan-Comment Re-Run Policy (Overwrite-In-Place)

On `/plan` re-runs that produce a new Named Decisions set, Issue-Planner overwrites the existing `## Named Decisions` H2 block in-place inside the `<!-- plan-issue-{ID} -->` comment. This matches the existing SMC-01 plan-comment amend semantics: the plan comment is a single durable artifact that gets edited, not duplicated.

The Named Decisions section content is intentionally **excluded** from the normalized-comparison hash that SMC-01's idempotency check uses to detect "no-op re-runs", so an amended classification (e.g., a previously routine decision re-audited to load-bearing) still triggers a fresh engagement-record marker even when the rest of the plan is byte-equivalent. A new `<!-- engagement-record-plan-{ID} -->` marker is posted as a new comment per cycle; latest-comment-wins resolves to the most recent set.

### D8 - `phase: plan` Schema Entry & Helper Updates

The canonical schema in `skills/engagement-record-emission/SKILL.md` is extended:

- `phase` enum becomes `experience | design | plan` (previously `experience | design`).
- `schema_version` bumped to `2` (see D4 rollout policy).
- The `adversarial_verdicts` block is **deferred** from #576's scope; SKILL.md strikes it from the canonical schema until a follow-up issue defines its shape. The existing `<!-- design-phase-complete-{ID} -->` marker's `finding_dispositions:` YAML block remains the authoritative adversarial-review audit surface per SMC-19.

The helper at `.github/scripts/lib/frame-engagement-record-core.ps1` is updated in lockstep: the `[ValidateSet]` attribute on `-Phase`, the body-level enum check, the header doc-comment, and the previous "throws on plan" MF10 test guard all accept the three-phase set. The unknown-`schema_version` throw is preserved.

### D9 - `capture_session` Literals Per Phase

Each upstream agent body locks its `capture_session` literal:

- Experience-Owner: `capture_session: "normal-experience-v2"`
- Solution-Designer: `capture_session: "normal-design-v2"`
- Issue-Planner: `capture_session: "normal-plan-v2"`

Hard-coding the literal in the agent body (rather than computing it at emit time) keeps the byte-equivalence test in AC6 tractable: writers can be diffed for placeholder substitution rather than runtime construction. The dogfood emission for this very /design session uses `normal-design-v2`.

> **Note on naming**: agent-body citations elsewhere in this repo that reference "D9 normalized-comparison hash exclusion" point at the SMC-01 plan-comment hash described in D7 above; D9 in this design doc concerns `capture_session` literals.

### D10 - `articulation_text` Capture Flow

At phase exit, writers emit `articulation_text: ""` (empty string) paired with `articulation_status: pending`. This is the documented initial state — not an authoring error — and signals that the CE Gate has not yet evaluated the decision.

The CE Gate work in #578 closes the loop: an evaluator reads the engagement record, assesses the engineer's articulation evidence, and transitions `articulation_status` to `complete` or `incomplete`. The Markdown mirror's `**Articulation text**: |` bullet renders as an empty multi-line block in the meantime; the agent bodies append the comment `<!-- CE Gate articulation pending per #578 -->` so the empty block reads as intentional rather than truncated.

### D11 - Section Divergence (Per-Agent Section Headers Preserved)

Each upstream agent's persistence section keeps its existing header — "Update Issue with Customer Framing" (EO), "Stage 4: Update Issue" (SD), "6. Persist Plan" (IP). Rather than collapsing these into one shared header, #576 adds a new `### Named Decisions write-discipline` H3 sub-section inside each.

The byte-equivalence test in AC6 asserts that the three H3 sub-sections are identical modulo three substitution variables: `{phase}` (the enum value), `{section-target}` (issue body for EO/SD; plan comment for IP), and `{marker-prefix}` (`engagement-record-experience` / `-design` / `-plan`). The sub-section is the byte-equivalent unit; the surrounding agent-specific persistence prose is intentionally per-agent.

### D12 - `## Named Decisions` H2 Placement in Issue Body

For /experience and /design phases (which write to the issue body, not a comment), the `## Named Decisions` H2 lands immediately **after** `## Scenarios` and **before** `## Acceptance Criteria`. When no `## Acceptance Criteria` section exists yet, it goes before the next non-AC H2. When `## Scenarios` is absent (Solution-Designer fallback), the H2 is appended at the end of the issue body.

AC6 includes a regression test that asserts Code-Conductor's pre-flight regex (anchored on `## Scenarios`) is unaffected by the new sibling H2.

The `## Named Decisions` H2 prose is also the customer-experience skill's "named decisions" surface for CE Gate verification (VERIFIED / NOT VERIFIED / VIOLATED). The two consumers share the slug namespace per D3; the SKILL.md adds a cross-reference disambiguating them so readers know whether "named decisions" in a given doc refers to the load-bearing classifications (engagement-record concern) or the customer-experience verification (CE Gate concern).

### D13 - Mixed-State Issue Gotcha

Issues that completed earlier phases pre-#576 (under `schema_version: 1` from #575) and later phases post-#576 (`schema_version: 2`) carry asymmetric resume coverage. `Read-EngagementRecords` accepts both v1 and v2 markers at parse time, so `same-decision-resume` works across the mixed state — but issues whose markers predate #575 entirely (no `schema_version` field) require the `-AcceptLegacy` switch to read, and without it remain opaque.

This is intentional: the rollout policy (D4) chose a hard schema-version bump over warn-and-skip degradation, so the documentation surface flags the mixed-state shape rather than hiding it.

### D14 - Dogfood Emission on Issue #576

Issue #576 itself emits `<!-- engagement-record-design-576 -->` at Stage 4 of /design with `schema_version: 2`, carrying D1/D2/D3/D4 as load-bearing decisions and their captured `engineer_choice` values. A second dogfood marker (`<!-- engagement-record-plan-576 -->`) is emitted at /plan completion, providing the first real `phase: plan` v2 fixture for AC6 round-trip tests.

This makes #576 the first issue under the v2 contract and provides a concrete reference fixture for #577 and #578 reader paths.

### D15 - Silent-Skip Cognitive-Surrender Follow-Up (Deferred to #580)

F24 from the design challenge surfaced a concern that `same-decision-resume`'s silent skip can become a different flavor of cognitive surrender when the maintainer's view legitimately evolves (new evidence, changed product direction) but the cached classification suppresses the re-audit question.

Fix candidates — a disclosure notice on resume activation, an in-band "re-open D-foo" lever, or a TTL on cached classifications — are intentionally out of scope for #576. The work is tracked as a #580 checklist item.

## Pre-merge Coordination Notes

The `schema_version: 2` hard cut requires coordinated reader updates before the writer side merges:

- **#577 (Code-Conductor solution-authoring integration)**: confirms its `Read-EngagementRecords` consumer paths accept `schema_version: 2` markers before #576 merges, OR confirms explicitly that Code-Conductor's runtime coupling stays no-op for now. Without that confirmation, the v2 cut creates a window where pre-#577 read paths throw on every v2 marker.
- **#578 (CE Gate exercise)**: scoped to read `schema_version: 2` markers and exercise the cross-tool resume axis (Copilot ↔ Claude) per AC6's cross-tool coverage hand-off.
- **`.claude-plugin/plugin.json` version bump**: included in #576's PR per `plugin-release-hygiene`. Same-version installs would otherwise serve the older cached helper that throws on v2 markers.

## Related Sources

- [skills/engagement-record-emission/SKILL.md](../../skills/engagement-record-emission/SKILL.md) - Canonical operational contract
- [CLAUDE.md](../../CLAUDE.md) - Cross-tool handoff marker registry
- [.github/scripts/lib/frame-engagement-record-core.ps1](../../.github/scripts/lib/frame-engagement-record-core.ps1) - Core library implementation
- [.github/scripts/Tests/named-decisions-write-discipline.Tests.ps1](../../.github/scripts/Tests/named-decisions-write-discipline.Tests.ps1) - Unit and integration tests
