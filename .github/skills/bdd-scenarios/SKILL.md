---
name: bdd-scenarios
description: Structured Given/When/Then scenario authoring with ID traceability and CE Gate coverage gap detection. Use when writing or reviewing BDD scenarios in Copilot Orchestra, classifying scenarios as [auto]/[manual], managing scenario ID lifecycle, or extracting scenario IDs for CE Gate pre-flight. DO NOT USE FOR: Gherkin test file conversion (Phase 2, deferred), framework-specific runner configuration, general test strategy (use test-driven-development), or writing example-based unit tests.
---

# BDD Scenarios

Structured Given/When/Then scenario authoring with ID traceability and CE Gate coverage gap detection for Copilot Orchestra.

## When to Use

- Writing G/W/T scenarios in GitHub issues (Experience-Owner upstream framing)
- Classifying scenarios as [auto] or [manual] (Issue-Planner)
- Verifying scenario ID coverage at CE Gate (Code-Conductor pre-flight)
- Per-scenario evaluation in adversarial CE prosecution (Code-Critic)
- Reviewing scenario authoring and classification quality

## G/W/T Authoring Patterns

- Scenarios use numbered IDs: S1, S2, S3…
- Heading convention: `### SN — {title} (Type)` where Type is Functional or Intent
- G/W/T clauses in customer language (no technical jargon, no implementation details)
- Example template:

  ```markdown
  ### S1 — User completes onboarding (Functional)

  Given a new user has opened the application for the first time
  When they follow the onboarding prompts
  Then they reach the home screen with personalized content
  ```

- Multiple Given or Then clauses allowed; And/But connectors supported for readability
- Each scenario must be independently understandable

## Scenario Type Tags

- **Functional**: Observable system behavior with clear pass/fail threshold. Use when the expected outcome is unambiguous and measurable.
- **Intent**: User-experience quality or design intent. Use when the outcome requires judgment (e.g., "feel", "clarity", "discoverability").
- Tag appears in the heading: `(Functional)` or `(Intent)`.

## Classification Rubric ([auto]/[manual])

BDD classification performed by Issue-Planner when BDD is enabled:

| Condition                                           | Classification        |
| --------------------------------------------------- | --------------------- |
| Functional + fully observable (grep/code assertion) | `[auto]`              |
| Intent + subjective judgment required               | `[manual]`            |
| Functional but requires UI interaction              | `[manual]` (override) |
| Any scenario requiring human judgment in CE Gate    | `[manual]` (override) |

Override rule: when in doubt, classify as `[manual]`. Test-Writer may reclassify `[auto]`↔`[manual]` during implementation; note the change in the plan and CE Gate evidence.

## Scenario ID Lifecycle

- IDs are **immutable after plan approval** — once S1, S2, S3 are assigned in the issue body and the plan is approved, those IDs do not change.
- If a scenario is split during implementation, the original ID remains; new sub-scenarios get the next sequential IDs (e.g., S1 stays S1; new scenario becomes S5).
- IDs are **never reused** — when a scenario is removed, its ID is retired, not reassigned.
- **Authority: the issue body is the authoritative source for scenario IDs**. The plan cites them; it does not define them. Post-approval additions to the issue body require a plan amendment.

## ID Extraction Format

When reading scenario IDs from an issue body:

- Match the pattern `### S\d+` headings within the `## Scenarios` section. Scope the extraction to content between the `## Scenarios` heading and the next H2 heading (`##`) — do not match `### S\d+` patterns outside this boundary.
- Extract the full heading: `### SN — {title} (Type)`
- IDs are ordinal integers starting at 1; gaps are valid (S1, S3, S4 — S2 was retired)
- For CE Gate pre-flight, extract all IDs present at plan-approval time and verify each appears in Experience-Owner's evidence summary

## BDD Detection Mechanism

BDD structured scenarios are only active when the consumer repo's `copilot-instructions.md` contains a `## BDD Framework` section heading. Absence of this heading = natural-language fallback. Agents check for this heading before applying BDD-specific authoring, classification, or pre-flight behavior.

## Gotchas

- **S-IDs vs Specification's AC-NNN format**: This skill uses `SN` IDs (S1, S2, S3) for CE Gate scenarios. Specification agent uses `AC-NNN` for acceptance criteria. These are different namespaces — do not mix them or treat AC-NNN as a scenario ID.
- **Customer language principle**: G/W/T keywords are structural framing only. The clause content must be in customer terms — no method names, no file paths, no agent names, no implementation details. "When the system calls ExperienceOwner.FrameScenarios()" is wrong; "When the team begins feature planning" is correct.
- **BDD detection gating**: All BDD-specific behavior (G/W/T authoring, classification, pre-flight, per-scenario prosecution) is conditional on `## BDD Framework` presence. Repos without this section keep the existing natural-language workflow unchanged — do not apply rubric, IDs, or pre-flight to natural-language scenarios.
- **Phase 2 scope boundary**: This skill covers Phase 1 only (structured authoring + traceability + coverage detection). Gherkin file conversion and consumer-side BDD framework runner configuration are Phase 2 scope — do not include or suggest those patterns here.
