# Cognitive Surrender Prevention Exercise Procedure

This document defines the manual verification procedure for proving that the cognitive-surrender prevention machinery (S2, S5, S6, S4) works reliably across sessions using falsifiable, durable evidence.

## (a) Purpose and Scenario Crosswalk

The cognitive-surrender-prevention machinery is only trustworthy if a maintainer can independently verify—across sessions and at audit points—that the promised experience (no surrender) actually holds, using durable evidence they could have falsified. This procedure exists so the umbrella closes on evidence rather than on assertion.

### Scenario Crosswalk

To ensure clear tracking, the table below maps this exercise document's local scenario IDs to the parent umbrella issue #571 scenarios:

| Exercise Scenario | Umbrella #571 Scenario | Goal / Description |
| --- | --- | --- |
| **S1** | *None (Procedure)* | Exercise procedure runs end-to-end using the written steps alone. |
| **S2** | **S2** (Resume) | Resume re-surfaces a recognized decision across sessions. |
| **S3** | **S4** (Articulation) | Independent maintainer articulation judgment (no self-grade). |
| **S4** | **S5** (Articulation-Debt)| Articulation-debt marker is captured by live phase-exit machinery. |
| **S5** | **S6** (Direction-Change) | Direction change engages and summarizes recommendations. |

---

## (b) Scenario Provisioning Table

Use the following provisioning recipe to prepare test issues, manage marker states, and run the pipeline commands.

| Scenario | Target Test Issue | Starting Marker State | Provisioned By | Pipeline Command(s) to Run |
| --- | --- | --- | --- | --- |
| **S1** | `#TEST-578-S1` | None | Maintainer | `pwsh -File .github/scripts/quick-validate.ps1` |
| **S2** | `#TEST-578-S2` | `<!-- engagement-record-experience-TEST-578-S2 -->` with genuine `articulation_text` | Maintainer / Session 1 | `pwsh -File .github/scripts/run-session.ps1 -Issue TEST-578-S2 -Phase experience` |
| **S3** | `#TEST-578-S3` | `<!-- engagement-record-design-TEST-578-S3 -->` with raw text | Maintainer | Manual inspection of the raw `articulation_text` |
| **S4** | `#TEST-578-S4` | Phase exit without articulation | Maintainer / CE Gate Evaluator | `pwsh -File .github/scripts/run-session.ps1 -Issue TEST-578-S4 -Phase design` |
| **S5** | `#TEST-578-S5` | material review verdict shift | Maintainer / Critic | `pwsh -File .github/scripts/run-session.ps1 -Issue TEST-578-S5 -Phase plan` |

---

## (c) The Two-Session Discipline (D2)

To verify cross-session same-decision-resume, a strict **two-session discipline** must be followed:

1. **Session 1 (Upstream Phase)**: Run a real upstream phase to completion on a fresh test issue. The session must produce a genuine, durable `engagement-record-{phase}-{ID}` marker comment containing a substantively authored `articulation_text`. Hand-authored or pre-seeded marker/articulation fixtures are **strictly disallowed**.
2. **Session 2 (Downstream Resume)**: In a completely distinct, fresh session (fresh tool invocation, new session start), re-enter the workflow and verify that the system successfully reads the durable marker and bypasses the structured question using the same-decision-resume rule.

---

## (d) Negative Control (mf-07)

Every maintainer verification of the same-decision-resume capability must run a **negative control** to distinguish genuine resume behavior from body re-derivation:

- **Procedure**: Run a control session where either (1) the issue body does NOT restate the decision, or (2) the `engagement-record` marker comment is temporarily withheld (e.g., deleted or hidden from the issue comment thread).
- **Control Bar**: Confirm that the workflow is forced to prompt the maintainer again for classification. If the scenario passes equally (bypasses the structured question) with and without the marker present, it must be recorded as a **FAIL**.

---

## (e) Falsifiable-Artifact Confirmation Bar (D1)

To prevent self-confirming attestations, bare assertions of success are rejected. Every maintainer confirmation must quote the specific rendered artifact it judges:

- **Resume**: Quote the exact console/log resume-note text (`Reusing prior {decision_id}: {engineer_choice}`).
- **Articulation**: Quote the verbatim `articulation_text` from the marker.
- **Direction-Change**: Quote the recommendation-shift/classification list inline.

---

## (f) Three-Part Thin-Articulation Criterion

Verbatim restatement from `skills/solution-authoring/SKILL.md:57-59` for independent evaluation:

> Articulation is substantive iff it contains: (1) the choice the engineer made, (2) what would have been wrong about a leading alternative, (3) the reasoning bridge between them. The agent renders the prompt and captures raw text; the agent does NOT grade articulation quality against the criterion in-flight (D-falsifiability protected). CE Gate evaluators apply the criterion independently.

---

## (g) Live-Machinery-Capture Rule

For **S4 (Articulation-Debt)**, the evidence must be captured from the live artifact written by the **CE Gate evaluator** itself at phase exit as it transitions `articulation_status` and recommendation state—not from pre-seeded or hand-authored marker state.

- The evaluator acts as the "live machinery."
- The procedure must not imply that an autonomous background emitter sets the `incomplete` status.

---

## (h) The `<!-- ce-gate-evidence-578 -->` Evidence-Capture Convention (D4)

All captured evidence from this exercise must be persisted under a single durable comment on the test issue:

- **Sentinel**: `<!-- ce-gate-evidence-578 -->`
- **Upsert Mechanism**: The comment must be upserted on re-runs using the existing repository helper:
  `Find-OrUpsertComment` (`.github/scripts/lib/find-or-upsert-comment.ps1`)
- **Marker-Collision Guard**: The sentinel MUST be `ce-gate-evidence-578` (and NOT `ce-evidence-578`). Because `Find-OrUpsertComment` matches sentinels via a substring check, using `ce-evidence-578` would match and clobber the design-phase handoff comments (like `design-phase-complete-{ID}` and `engagement-record-design-{ID}`).
- **Uniqueness Check**: Before running the first upsert, run a grep or issue comment check to ensure `ce-gate-evidence-578` is not present in any pre-existing comment thread.

---

## (i) Evidence-to-#571 Feedback Path (AC8)

Any ambiguous results, failed exercise scenarios, or verification gaps (specifically the orchestration-resume coverage gap) must be propagated to `#571`:

- **Write Target**: Because `#571` has no pre-existing "CE Gate Readiness section" and using `gh issue edit` is a non-idempotent full-body overwrite that risks clobbering concurrent maintainer edits, findings must be written to a dedicated, marker-delimited upsert comment.
- **Sentinel**: `<!-- ce-gate-readiness-571 -->`
- **Upsert Command**:

```powershell
pwsh -File .github/scripts/lib/find-or-upsert-comment.ps1 -Type issue -Number 571 -Sentinel "ce-gate-readiness-571" -Body "..."
```

This establishes the readiness section on first run and updates it idempotently thereafter.

---

## (j) Test-Issue Labelling and Cleanup Exemption Note

To prevent provisioned test issues (`#TEST-578-S1` through `#TEST-578-S5`) from being deleted or archived by the session-startup cleanup detector, they must carry the `ce-gate-exemption` label or include the `#ce-gate-exemption` token in the issue body. (Note: This is a configuration/labelling instruction; no exemption logic changes are introduced in #578).
