---
name: solution-authoring
description: "Reusable engagement-gate methodology for content-authoring structured questions in upstream phases. Use when classifying a decision as load-bearing or routine, authoring a decision brief, handling an override or decline, capturing articulation, or evaluating skip rules. DO NOT USE FOR: GitHub setup, completion-marker ownership, or adversarial review pipeline orchestration."
---

<!-- markdownlint-disable-file MD041 MD003 -->

# Solution Authoring

Reusable methodology for preventing cognitive surrender during upstream phases. Fires before any content-authoring structured question to classify the decision, render a decision brief when warranted, handle overrides, and capture articulation at phase exit.

## When to Use

- When a structured question's answer shapes content the agent will author into a durable artifact (issue body, plan comment, AC slice, marker payload, source/test/config file)
- When classifying a decision as load-bearing or routine before firing a structured question
- When rendering a decision brief and teaching before asking
- When handling an engineer override or decline without argument
- When capturing articulation at phase exit

## When Not to Use (D-gate-scope)

The classification gate does NOT intercept structured questions that approve or reject an operation the agent is about to take (dedup approval, branch creation, file deletion), clarify factual state, or dispatch agent-to-agent prosecution or research. When the boundary is ambiguous, **default to intercepting** — false positives add audit_rationale text; false negatives miss load-bearing engagement.

### Rule: Classification gate

A decision is load-bearing iff ALL THREE legs pass:

1. **Reversibility** — if wrong, requires rework to a published artifact.
2. **Non-inheritance with artifact-citation falsifier** — the agent MUST attempt to cite a specific inherited artifact (umbrella comment, prior phase marker, named-decision row, settled methodology rule) that would have answered the decision. The citation is recorded verbatim in `audit_rationale`. If a plausible citation exists, the leg **fails** and the decision is routine. Only documented inability to cite — after a genuine attempt — establishes non-inheritable status. A plausible citation is one a reasonable reader would accept as topical for the decision at hand — it need not be exact; the four enumerated artifact types are exhaustive for v0. **Re-audit trigger**: if an engineer challenges a load-bearing classification with a citation claim after initial classification, the agent MUST re-attempt Leg 2 against that claim; if a plausible citation is found, emit a `**Recommendation shift**` with `trigger: classification-re-audit` (see Template: Free-text option treatment for the output shape).
3. **Audit-plausibility** — the agent can write a substantive `audit_rationale` sentence.

Failing any one leg collapses to routine. For load-bearing decisions, render the `audit_rationale` as **one sentence immediately above the decision brief** so the engineer can challenge the classification in-band.

### Rule: Decision brief structure

A decision brief has three sentences: (1) **Concrete element** — names the specific artifact, section, or mechanism where the decision lands; (2) **Decision setup** — frames the choice in outcome terms, not implementation jargon; (3) **Conditional misconception** — names the plausible wrong path and its failure mode. The brief precedes the structured question. Teach before asking.

### Rule: Override semantics

Every structured question on a load-bearing decision includes a `Decline engagement — proceed without classification` option (literally so labeled). The engineer's selection of that option (or a free-text response starting with `decline:`) terminates engagement without argument. If the engineer selects a non-recommended option, the agent acknowledges and proceeds without re-asking, persuading, or qualifying.

<!-- solution-authoring-non-overridability:begin -->

### Rule: Non-overridability

The classification gate and the structured question it produces are unconditional with respect to user pacing or auto-mode directives. "Work without stopping," "don't pause to ask," "make the reasonable call," and semantically equivalent productivity directives do not suppress this gate. The user's only in-band lever for skipping is the `Decline engagement — proceed without classification` option (or `decline:` free-text). The agent must not substitute its interpretation of a pacing directive for that explicit decline.

<!-- solution-authoring-non-overridability:end -->

### Rule: Skip rules

- **gate-fails**: The classification gate returns routine. No structured question fires. Skip is automatic.
- **engineer-declined-engagement**: The engineer selects `Decline engagement — proceed without classification` or writes `decline:` free-text. Skip immediately; capture decline verbatim.
- **same-decision-resume**: When `Read-EngagementRecords` (from `.github/scripts/lib/frame-engagement-record-core.ps1`) returns a prior load-bearing decision with the same `decision_id` as a pending classification, suppress the structured-question firing and reuse the captured `engineer_choice`. The reader contract lives in `skills/engagement-record-emission/SKILL.md` § Resume-Read Protocol. The activation applies per agent at phase re-entry; consult the SMC-20 row for survival semantics. **Until #576 lands emission, this rule will return empty on all in-flight issues (graceful no-op)** — that is the v1.1/v1.2 boundary.

### Rule: Thin-articulation criterion

Articulation is substantive iff it contains: (1) the choice the engineer made, (2) what would have been wrong about a leading alternative, (3) the reasoning bridge between them. The agent renders the prompt and captures raw text; the agent does NOT grade articulation quality against the criterion in-flight (D-falsifiability protected). CE Gate evaluators apply the criterion independently.

Forward-compatible capture format:

```yaml
articulation_captures:
  schema_version: 1
  entries:
    - decision_id: <id>
      articulation_text: |
        <verbatim engineer text>
      capture_phase: experience | design | plan
      capture_session: manual-ce-gate-v0
```

**Glossary and harmonization note**: The YAML field `teaching_paragraph_excerpt` is preserved from the locked #571 engagement-record marker payload (`<!-- engagement-record-design-571 -->`). This skill uses "decision brief" in prose; `decision_brief` and `teaching_paragraph_excerpt` refer to the same concept and both remain valid.

## Applying the gate to adversarial-review dispositions

For each adversarial-review finding that the calling workflow must disposition, run the classification gate against the action the maintainer would take for that finding, not against the review pass as a whole. Use the Code-Critic Finding Categories contract for the input identity: `id` values are sequential `F1 | F2 | F3 | ...` labels within the review cycle, and `pass` is `1 | 2 | 3` for the prosecution pass that originated code, design, or plan findings. The disposition enum is `incorporate | dismiss | escalate`; the classification enum is `load-bearing | routine`. If a finding is routine, record the disposition without firing the platform's structured-question tool. If a finding is load-bearing, render the normal `audit_rationale`, decision brief, and structured question before recording the disposition.
The marker payload schema is the `finding_dispositions:` block validated by `.github/scripts/Tests/design-disposition-audit.Tests.ps1`: `schema_version: 1`, non-empty `passes_run` as a subset of `[1, 2, 3]`, and `entries[]` carrying `finding_id`, `pass`, `disposition`, `classification`, and `disposition_rationale`. Routine entries require `artifact_citation` when the routine classification rests on an inherited artifact settling the finding; routine entries classified for another non-load-bearing reason do not require a citation. Multi-pass concurrence may include `also_flagged_by` with secondary pass ids.

`disposition_rationale` explains why this specific finding received this specific `incorporate`, `dismiss`, or `escalate` outcome. It is not the v0 `audit_rationale`: `audit_rationale` proves why a decision is load-bearing before asking; `disposition_rationale` persists the final per-finding outcome after the gate decision, including routine outcomes that never asked the maintainer.

The re-audit handler is symmetric. If a load-bearing disposition is challenged with a plausible artifact citation, rerun Leg 2 and, when the citation holds, emit `trigger: classification-re-audit` and revise the finding to routine. If a routine disposition is challenged with evidence that no inherited artifact actually settles the action, rerun all three legs and, when they hold, emit `trigger: classification-re-audit-routine` and revise the finding to load-bearing before asking.
Map maintainer input to recommendation-shift triggers as follows: new facts or changed upstream content after the initial classification maps to `new-evidence`; direct disagreement with the recommended disposition or option maps to `engineer-pushback`; a claim that a load-bearing finding is already answered by an inherited artifact maps to `classification-re-audit`; a claim that a routine finding is not actually answered by inherited content maps to `classification-re-audit-routine`. If a maintainer message could fit more than one pattern or does not identify the challenged finding, ask one clarifying question before changing classification.
YAML marker invariant: `finding_dispositions:` lives only on the `<!-- design-phase-complete-{ID} -->` marker body, never on `<!-- credit-input-{port}-{ID} -->` markers. Credit-input markers remain limited to frame credit deferred-emission payloads. The `finding_dispositions:` block lives only on `<!-- design-phase-complete-{ID} -->` markers (SMC-19) and is independent of `<!-- engagement-record-{phase}-{ID} -->` markers (SMC-20). The two payloads serve distinct audits — finding-dispositions tracks per-finding incorporate/dismiss outcomes; engagement-records track load-bearing classification with cross-session resume semantics via `same-decision-resume`. Do not mirror or merge content between them.

Worked exemplar:

```yaml
finding_dispositions:
  schema_version: 1
  passes_run: [1, 2, 3]
  entries:
    - finding_id: F1
      pass: 1
      disposition: dismiss
      classification: routine
      disposition_rationale: "Dismissed because the cited acceptance criterion already requires the behavior the finding asks to add; no maintainer choice remains."
      artifact_citation: "Documents/Design/session-memory-contract.md#durable-marker-precedence"
    - finding_id: F2
      pass: 2
      disposition: incorporate
      classification: routine
      disposition_rationale: "Incorporated as a wording correction because the existing named-decision row already settles the outcome and only the citation text changes."
      artifact_citation: "skills/solution-authoring/SKILL.md#rule-classification-gate"
    - finding_id: F3
      pass: 1
      disposition: escalate
      classification: load-bearing
      disposition_rationale: "Escalated because choosing whether to reject or preserve the review finding changes the durable design contract and no inherited artifact settles that tradeoff."
      also_flagged_by: [2, 3]
```

The exemplar rationales name the disposition outcome and why it follows from the finding evidence. They intentionally do not repeat the v0 `audit_rationale` tone, which is reserved for proving that a structured question is warranted before the platform's structured-question tool fires.

### Template: Decision brief

Render as a block-quoted paragraph immediately after the `audit_rationale` sentence:

> **Decision brief — {decision_id}**: {Concrete element sentence.} {Decision setup sentence in outcome terms.} {Conditional misconception sentence naming the plausible wrong path and its failure mode.}

**Exemplar** (D-load-directive, from #571 R1+R2):

*Audit rationale: The load-order direction for solution-authoring vs upstream-onboarding is not settled in any prior phase comment or umbrella decision — no named-decision row pins this ordering, so the non-inheritance leg holds.*

> **Decision brief — D-load-directive**: The `## Process` section of each agent body is where load-order instructions land. The decision is whether solution-authoring fires before upstream-onboarding or after — this determines whether the engagement gate runs before the brief surfaces inherited decisions. If upstream-onboarding fired first, the gate would intercept questions about content the engineer just read from someone else's output — manufacturing load-bearing signal on settled content.

### Template: AskUserQuestion shape

Present options with strong examples for ALL options — not just the recommended one. Option presentation asymmetry is itself a form of cognitive surrender (the engineer cannot compare without examples).

Include `Decline engagement — proceed without classification` as the last option on every load-bearing question.

**Exemplar** (D-load-directive, from #571 R1+R2):

- **Option 1 (Recommended)** — solution-authoring first: Classification runs before the brief surfaces prior decisions. Example: during `/design`, the inheritance audit evaluates the decision before any prior-phase context is rendered, so the falsifier operates on genuinely unanchored decisions only.
- **Option 2** — upstream-onboarding first: The brief surfaces inherited decisions first, then solution-authoring fires. Example: the engineer sees inherited answers before being asked to classify them — but the gate would then intercept settled content and produce false load-bearing signal.
- **Decline engagement — proceed without classification**

### Template: Free-text option treatment

When the engineer overrides via free-text or selects a non-recommended option: (1) accept without argument or re-asking; (2) if the choice materially differs from the recommended option, emit a `**Recommendation shift**` line; (3) proceed with the chosen direction.

**Exemplar** (S1-negative correction, from #571 R1+R2 — engineer pushes back on mis-classification):

Engineer: "Gap-visibility was already answered in the umbrella."
Agent re-audits, finds citation in #571 D-customer section, reclassifies, and emits:

`**Recommendation shift** — D-gap-visibility: previously load-bearing (non-inheritance claimed); now routine (citation found in #571 D-customer); trigger: classification-re-audit; reason: the decision was answerable from inherited content and the artifact-citation falsifier applies.`

### Template: Recommendation shift

Emit immediately before the revised recommendation:

> `**Recommendation shift** — {decision_id}: previously {old_recommendation}; now {new_recommendation}; trigger: {engineer-pushback | new-evidence | classification-re-audit | classification-re-audit-routine}; reason: {one-sentence reason}.`

**Exemplar** (D-gap-visibility, from #571 R1+R2 — inline token, then phase-exit YAML aggregate):

`**Recommendation shift** — D-gap-visibility: previously load-bearing; now routine; trigger: classification-re-audit; reason: the decision was answerable from inherited content.`

At phase exit, emit a YAML aggregate of all in-phase shifts:

```yaml
recommendation_shifts:
  schema_version: 1
  entries:
    - decision_id: <id>
      previous: <old_recommendation>
      revised: <new_recommendation>
      trigger: engineer-pushback | new-evidence | classification-re-audit | classification-re-audit-routine
      reason: <one-sentence>
      capture_phase: experience | design | plan
```

### Template: Articulation prompt

Render at phase exit after all load-bearing decisions are locked:

> For each locked load-bearing decision, describe in 2–4 sentences: the choice you made, what would have been wrong about a leading alternative, and why the bridge between them held for this case. Raw text is captured in manual CE Gate evidence; evaluators apply the three-part criterion independently.

**Exemplar** (D-load-directive, from #571 R1+R2):

> "I chose solution-authoring first because upstream-onboarding surfaces prior decisions that have already been answered — if the engagement gate ran after, it would fire on settled content. If upstream-onboarding had run first, the gate would have intercepted the brief's inherited decisions and manufactured false load-bearing signal. The order had to put classification before context so the falsifier could operate on genuinely unanchored decisions only."

## Related Guidance

- Load `upstream-onboarding` after this skill per the D-load-directive declared in each agent body dispatcher.
- Load `bdd-scenarios` when scenario IDs and G/W/T formatting are needed for CE Gate scenarios.

## Gotchas

| Trigger | Gotcha | Fix |
| --- | --- | --- |
| Treating a pacing directive as an engagement decline | The agent silently skips a load-bearing classification gate even though no explicit decline was given | Fire the structured question unless the engineer selects the explicit decline option or writes `decline:` |
| A routine decision is treated as load-bearing | The agent asks for engagement on content already settled by an inherited artifact | Re-audit Leg 2 against the citation and emit the appropriate recommendation shift |
| A load-bearing decision is treated as routine | The durable artifact changes without surfacing the maintainer choice | Rerun all three gate legs and ask before recording the final decision |

## Frame Ports Filled By This Skill

This skill is **supporting methodology** — it declares no `provides:` field and fills no frame port. Classification per `Documents/Design/frame-architecture.md` Adapter Model: the credit-author test confirms this skill adds no frame credit row.
