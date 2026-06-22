---
name: code-review-intake
description: "Deterministic GitHub review intake workflow with ledger-based judgment. Use when processing GitHub code review comments, reconciling Code-Critic findings, or running GitHub review intake mode. DO NOT USE FOR: pre-PR readiness checks (use verification-before-completion) or post-merge cleanup (use post-pr-review)."
---

<!-- markdownlint-disable-file MD041 MD003 -->

# Code Review Intake

Slim entryway for GitHub review intake, proxy-prosecution guardrails, and the extracted express-lane boundary reference.

## When to Use

Activate this skill when the request includes `github review`, `review github`, or `cr review`. It is the entryway for deterministic intake and judgment of GitHub-originated review feedback before implementation begins, while shared mechanics stay indexed in extracted references.

### Shared judgment surface with non-GitHub review

The GitHub-intake path consumes the same `agents/Code-Review-Response.agent.md` judge body as the non-GitHub review path and therefore the same structural-criteria deferral gate. Findings ingested from GitHub are classified against the canonical criterion taxonomy in `skills/review-judgment/scripts/Test-DeferralCriteria.ps1` (the predicates), and any `DEFERRED-SIGNIFICANT (structural)` outcome is filed via `skills/safe-operations/scripts/Add-FollowUpIssue.ps1` (the filing helper). To guarantee AC7 dedup correctness across both paths, the GitHub-intake filing call canonicalizes the title with `ConvertTo-CanonicalFollowupTitle` (from the same helper file) and runs §2c dedup-on-create against the canonicalized title before invoking `Add-FollowUpIssue` — identical to the Code-Conductor non-GitHub path. The GitHub-intake path MUST also call `Get-AcTermsFromIssue` (ARM 2) alongside `Get-AcRefsFromIssue` (ARM 1) before invoking `Get-StructuralVerdict`, so that behavioral-term AC cross-check fires for GitHub-ingested findings — identical to the Code-Conductor path. The `ac_cross_check` OUT object is required for any `dismiss`/`defer` disposition entry at severity ≥ medium per the v2 schema.

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

- ✅ ACCEPT (fix inline)
- 📋 DEFERRED-SIGNIFICANT (structural)
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
| Routing implementation work before all judgment states are explicit              | Fixes applied to some findings may contradict pending rulings on others                      | All items must reach terminal state (ACCEPT / REJECT / DEFERRED-SIGNIFICANT (structural)) before any routing |
| Treating a reviewer preference comment as a defect                               | Evidence-free rejection inflates fix scope and wastes implementation cycles                  | Reject by default; require cited code, test output, or acceptance criteria evidence             |
| Running rebuttal rounds after the judge rules                                    | Proxy prosecution is single-shot; post-judge rebuttals break convergence                     | Judge rules final; unresolved low-confidence items go async via GitHub comment                  |
| Accepting a finding just because it's consistently raised across multiple passes | Repetition is not evidence of correctness                                                    | Each finding still requires concrete evidence regardless of how many passes surface it          |

## Response Loop Completion (Terminal Step)

After all judgment states reach terminal, the GitHub-intake response loop completes with these ordered steps:

1. **Disposition gate** — honor the `<!-- review-dispositions-{PR} -->` marker: skip findings with `disposition: escalate`; only `disposition: incorporate` entries proceed.
2. **Batch Specialist Dispatch (R4)** — dispatch accepted findings to specialists (see `skills/validation-methodology/references/review-reconciliation.md § Batch Specialist Dispatch (R4)`).
3. **Post-fix targeted prosecution pass** — when triggered per the R2 conditions (see `skills/validation-methodology/references/review-reconciliation.md § Post-Fix Targeted Prosecution Pass`).
4. **CE Gate** — run the CE Gate when a customer surface is affected (see `agents/Code-Conductor.agent.md § Customer Experience Gate`).
5. **Persist changes** — fire `skills/persist-changes/SKILL.md` as the terminal step (see `### Response Commit & Push` in `skills/validation-methodology/references/review-reconciliation.md` for the SSOT contract). The executor commits fix files and pushes to the PR's head remote, or surfaces a loud not-pushed reason.
6. **Response Summary** — assemble and return the Response Summary per the shape in `skills/validation-methodology/references/review-reconciliation.md § Response Commit & Push`.

This step sequence is what makes a bare `/review-github` complete the full response loop — accepted fixes are applied, committed, and pushed to the existing PR branch without requiring an additional user instruction.

> **Invariant preserved**: the routing gate at line 74 of this file ("All items must reach terminal state… before any routing") applies to fix-dispatch routing only — this section documents the post-routing terminal completion steps.
