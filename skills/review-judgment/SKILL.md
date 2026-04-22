---
name: review-judgment
description: "Reusable single-shot review judgment methodology for scoring prosecution and defense ledgers, verifying evidence, and emitting judge output. Use when ruling on review findings after prosecution and defense are available. DO NOT USE FOR: GitHub review intake routing, response-location policy, or fix execution ownership (keep those in Code-Review-Response.agent.md)."
---

<!-- platform-assumptions: markdown skill guidance for VS Code custom agents in Agent Orchestra; assumes the calling agent owns intake routing, categorization policy, and handoff to implementation. -->
<!-- markdownlint-disable-file MD041 MD003 -->

# Review Judgment

Reusable judgment method for a single referee pass over prosecution and defense.

## When to Use

- When prosecution findings and defense responses are both available
- When a judge must independently verify claims before ruling
- When a scored review summary and machine-readable ruling block are required
- When external review comments have already been converted into a prosecution ledger

## Purpose

Make one final, evidence-backed ruling per finding. The goal is not to split the difference between prosecutor and defense, but to decide whether the proposed change would improve the code and to record that decision in a format the pipeline can consume.

## Single-Shot Judgment Workflow

1. Read the prosecution finding, including severity, points, citation, and failure mode.
2. Read the defense response and note whether it disproves, concedes, or cannot disprove the claim.
3. Verify the evidence independently.
4. Rule once: prosecution sustained or defense sustained.
5. Emit score, confidence, and structured output.

No rebuttal rounds. Uncertain items still need a ruling.

## Improvement Test

Ask this first for every item:

1. Will acting on this finding improve the code?

Outcomes:

- Yes -> accept the improvement
- No -> reject it
- Unclear even after verification -> reject it for now

Uncertainty is not a deferral bucket. If improvement cannot be shown with evidence, do not accept it.

## Independent Verification Expectations

Before sustaining a finding:

- Read the cited code, config, test, or document directly
- Confirm the claimed defect actually exists
- State what was verified, not just what the prosecutor said

When the cited evidence does not support the claim, sustain the defense and explain the mismatch clearly.

## Scoring Model

Severity maps to points as follows:

- `critical` or `high` -> 10 points
- `medium` -> 5 points
- `low` -> 1 point

Judges may override the prosecution severity when verification shows the impact is lower or higher than claimed.

Confidence guidance:

- `high` -> direct structural proof, test output, or explicit code evidence
- `medium` -> evidence leans one way but is not fully conclusive
- `low` -> honest uncertainty after reasonable verification

## Score Summary Output

Emit a score table after ruling all findings.

```markdown
### Adversarial Review Score Summary

| Finding     | Pass | Prosecution (severity, pts) | Defense verdict | Ruling                   | Confidence | Points    |
| ----------- | ---- | --------------------------- | --------------- | ------------------------ | ---------- | --------- |
| F1: {title} | {N}  | {severity} ({pts} pts)      | conceded        | ✅ Sustained             | high       | P+{pts}   |
| F2: {title} | {N}  | {severity} ({pts} pts)      | disproved       | ❌ Defense sustained     | medium     | D+{pts}   |
| F3: {title} | {N}  | {severity} ({pts} pts)      | disproved       | ✅ Prosecution sustained | high       | D-{2×pts} |

**Totals**

- Prosecutor: {sum of sustained prosecution points} pts ({N} findings sustained)
- Defense: {net points after rejected-disproof penalties} pts
- Judge rulings: {total} ({N} pending user scoring)
```

Use `—` in the Pass column when the prosecution mode does not carry a pass number.

## Structured Judge Output

After the Markdown table, emit the completion marker and `judge-rulings` block in the same payload:

```yaml
<!-- code-review-complete-{PR} -->
<!-- judge-rulings
- id: F1
  judge_ruling: sustained
  judge_confidence: high
  points_awarded: P+10
- id: F2
  judge_ruling: defense-sustained
  judge_confidence: medium
  points_awarded: D+5
-->
```

Keep the Markdown score summary, the `<!-- code-review-complete-{PR} -->` marker, and the `judge-rulings` block together in the same response payload. For GitHub-backed review flows, keep them in the same PR comment rather than splitting them across separate comments.

Field values:

- `judge_ruling`: `sustained` or `defense-sustained`
- `judge_confidence`: `high`, `medium`, or `low`
- `points_awarded`: `P+{pts}`, `D+{pts}`, or `D-{2×pts}`

## General Judgment Workflow

### Default Path

- Verify the finding
- Rule on it
- Categorize it according to the calling agent's policy
- Stop after emitting the judgment output

### Evidence-First Rejection

When rejecting, cite the reason explicitly:

- The code contradicts the finding
- Tests or types already guarantee the claimed invariant
- The documented design makes the proposed change harmful
- The reviewer's cited evidence is factually wrong

### Escalation Boundary

Judgment does not implement fixes. It produces the ruling and the evidence package needed for the owning orchestrator to route accepted work.

## Related Guidance

- Load `adversarial-review` for prosecution and defense methodology
- Load `code-review-intake` when GitHub review retrieval and ledger construction are the main problem

## Gotchas

| Trigger                                   | Gotcha                                                   | Fix                                                          |
| ----------------------------------------- | -------------------------------------------------------- | ------------------------------------------------------------ |
| The judge repeats the prosecutor verbatim | The ruling becomes a rubber stamp instead of independent | Read the cited artifact directly and state what was verified |

| Trigger                             | Gotcha                                                         | Fix                                                                |
| ----------------------------------- | -------------------------------------------------------------- | ------------------------------------------------------------------ |
| A ruling omits the completion marker or structured block | Downstream consumers can miss completion or fail to route cleanly | Emit `<!-- code-review-complete-{PR} -->` and the `judge-rulings` block immediately after the score summary in the same payload |
