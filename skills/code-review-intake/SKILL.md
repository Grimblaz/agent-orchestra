---
name: code-review-intake
description: "Deterministic GitHub review intake workflow with ledger-based judgment. Use when processing GitHub code review comments, reconciling Code-Critic findings, or running GitHub review intake mode. DO NOT USE FOR: pre-PR readiness checks (use verification-before-completion) or post-merge cleanup (use post-pr-review)."
---

<!-- markdownlint-disable-file MD041 MD003 -->

# Code Review Intake

Slim entryway for GitHub review intake, proxy-prosecution guardrails, and the extracted express-lane boundary reference.

## When to Use

Activate this skill when the request includes `github review`, `review github`, or `cr review`. It is the entryway for deterministic intake and judgment of GitHub-originated review feedback before implementation begins, while shared mechanics stay indexed in extracted references.

## GitHub Review Mode (Proxy Prosecution Pipeline)

1. Ingest all review items from GitHub (threads, top-level comments, review summaries).
2. Build a finding ledger where each item maps to its GitHub comment/review ID.
3. **Proxy prosecution**: Call Code-Critic with the selector line `Review mode selector: "Score and represent GitHub review"`. Code-Critic validates and scores each GitHub comment (critical/high→10 pts, medium→5 pts, low→1 pt). Output: scored prosecution ledger.
4. **Defense pass**: Call Code-Critic with the selector line `Review mode selector: "Use defense review perspectives"`, passing the prosecution ledger.
5. **Judge pass**: Call Code-Review-Response with both prosecution ledger and defense report. Judge rules final and emits score summary.

## Hard Guardrail

In GitHub Review Mode, do not add net-new findings outside the ingested GitHub ledger. GitHub review mode is proxy prosecution, so the R6 express lane does not apply. See [references/express-lane.md](references/express-lane.md) for the canonical scope restriction and Tier 1 re-validation rule.

### Safety Exception

A new item may be added only for a critical correctness/security blocker discovered during verification. It must:

- Be tagged `NEW-CRITICAL`
- Include concrete evidence
- Be explicitly surfaced to the user

## Judgment Guardrail

Judgment is evidence-first and deterministic:

- Every accepted/rejected/deferred item cites code, test output, architecture constraints, or issue AC evidence.
- Preference-only comments without evidence are rejected by default.
- Conflicting evidence keeps an item in disputed state until resolved or escalated.
- Do not route implementation work until judgment states are explicit.

## Convergence Criteria

Converged when all items are in a terminal state:

- ✅ ACCEPT
- 📋 DEFERRED-SIGNIFICANT
- ❌ REJECT

Plus:

- No unresolved evidence disputes remain.
- User has visibility before any authority-boundary decision gate.

The proxy prosecution pipeline is single-shot: prosecution → defense → judge, with no rebuttal rounds. Judge rules final on all items. Unresolved items at low judge confidence are surfaced for user scoring via GitHub issue comment (async, non-blocking).

## Composite References

- [references/express-lane.md](references/express-lane.md): canonical R6 express-lane gate, its exclusion from proxy prosecution, and the Tier 1 re-validation requirement when R6 is used elsewhere
- [../validation-methodology/references/review-reconciliation.md](../validation-methodology/references/review-reconciliation.md): shared non-GitHub review reconciliation, prosecution-depth setup, and post-fix R2 review mechanics that pair with intake after proxy judgment completes

## Gotchas

| Trigger                                                                          | Gotcha                                                                                       | Fix                                                                                             |
| -------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------- |
| Spotting a new bug while reading GitHub review comments                          | Adding it informally bypasses the prosecution → defense pipeline and breaks ledger integrity | Surface as `NEW-CRITICAL` with concrete evidence only; present to user explicitly for decision  |
| Routing implementation work before all judgment states are explicit              | Fixes applied to some findings may contradict pending rulings on others                      | All items must reach terminal state (ACCEPT / REJECT / DEFERRED-SIGNIFICANT) before any routing |
| Treating a reviewer preference comment as a defect                               | Evidence-free rejection inflates fix scope and wastes implementation cycles                  | Reject by default; require cited code, test output, or acceptance criteria evidence             |
| Running rebuttal rounds after the judge rules                                    | Proxy prosecution is single-shot; post-judge rebuttals break convergence                     | Judge rules final; unresolved low-confidence items go async via GitHub comment                  |
| Accepting a finding just because it's consistently raised across multiple passes | Repetition is not evidence of correctness                                                    | Each finding still requires concrete evidence regardless of how many passes surface it          |
