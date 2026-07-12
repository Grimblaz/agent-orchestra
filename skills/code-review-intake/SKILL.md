---
name: code-review-intake
description: "Deterministic GitHub review intake workflow with ledger-based judgment. Use when processing GitHub code review comments, reconciling Code-Critic findings, or running GitHub review intake mode. DO NOT USE FOR: pre-PR readiness checks (use verification-before-completion) or post-merge cleanup (use post-pr-review)."
---

<!-- markdownlint-disable-file MD041 MD003 -->

# Code Review Intake

Slim entryway for GitHub review intake, proxy-prosecution guardrails, and the extracted express-lane boundary reference.

## When to Use

Activate this skill when the request includes `github review`, `review github`, or `cr review`. It is the entryway for deterministic intake and judgment of GitHub-originated review feedback before implementation begins, while shared mechanics stay indexed in extracted references.

The GitHub-intake path consumes the same `agents/Code-Review-Response.agent.md` judge body as the non-GitHub review path and therefore the same structural-criteria deferral gate. Findings ingested from GitHub are classified against the canonical criterion taxonomy in `skills/review-judgment/scripts/Test-DeferralCriteria.ps1` (the predicates), and any `DEFERRED-SIGNIFICANT (structural)` outcome is routed through the `§2e Filing Approval Gate` (`skills/safe-operations/SKILL.md` § 2e) before it is filed via `skills/safe-operations/scripts/Add-FollowUpIssue.ps1` (the filing helper) — consistent with how Code-Conductor's Auto-Tracking sequence routes structural deferrals. Before calling `Add-FollowUpIssue` (or any bare `gh issue create`) for structural deferrals, apply the board-positioning decision per `skills/safe-operations/SKILL.md §2b`, §2b-bis, and §2b-ter. To guarantee AC7 dedup correctness across both paths, the GitHub-intake filing call canonicalizes the title with `ConvertTo-CanonicalFollowupTitle` (from the same helper file) and runs §2c dedup-on-create against the canonicalized title before invoking `Add-FollowUpIssue` — identical to the Code-Conductor non-GitHub path. The GitHub-intake path MUST also call `Get-AcTermsFromIssue` (ARM 2) alongside `Get-AcRefsFromIssue` (ARM 1) before invoking `Get-StructuralVerdict`, so that behavioral-term AC cross-check fires for GitHub-ingested findings — identical to the Code-Conductor path. The `ac_cross_check` OUT object is required for any `dismiss`/`defer` disposition entry at severity ≥ medium per the v2 schema.

## GitHub Review Mode (Proxy Prosecution Pipeline)

1. Ingest all review items from GitHub (threads, top-level comments, review summaries).
2. Build a finding ledger where each item maps to its GitHub comment/review ID.
3. **Proxy prosecution**: Call Code-Critic with the selector line `Review mode selector: "Score and represent GitHub review"`. Code-Critic validates and scores each GitHub comment (critical/high→10 pts, medium→5 pts, low→1 pt). Output: scored prosecution ledger.
4. **Defense pass**: Call Code-Critic with the selector line `Review mode selector: "Use defense review perspectives"`, passing the prosecution ledger.
5. **Judge pass**: Call Code-Review-Response with both prosecution ledger and defense report. Judge rules final and emits score summary.

## Hard Guardrail

In GitHub Review Mode, do not add net-new findings outside the ingested GitHub ledger. GitHub review mode is proxy prosecution, so the R6 express lane does not apply. See [references/express-lane.md](references/express-lane.md) for the canonical scope restriction and Tier 1 re-validation rule.

### Ledger-vs-Validation Boundary

Ingestion and ledger-building (steps 1–2) are mechanical: the conductor records each ingested finding verbatim and maps it to its GitHub comment/review ID. The conductor MUST NOT independently assess the technical merit of an ingested finding — neither accepting it, rejecting it, nor forming any per-finding correctness verdict — before proxy prosecution runs. Per-finding validation is the proxy prosecution pass's responsibility (step 3).

Reading an ingested finding closely enough to record it and map it to its GitHub comment/review ID is expected; forming a verdict on whether it is *correct* — or assigning your own severity/type classification ahead of proxy prosecution — is not. The `NEW-CRITICAL` safety exception below — which concerns a *newly discovered* critical blocker, not an ingested finding — is the only conductor-side correctness judgment permitted before proxy prosecution.

### Safety Exception

A new item may be added only for a critical correctness/security blocker discovered during verification. It must be tagged `NEW-CRITICAL`, include concrete evidence, and be explicitly surfaced to the user.

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
- [references/response-loop-completion.md](references/response-loop-completion.md): ordered terminal-step sequence (disposition gate, R4 dispatch, post-fix prosecution, CE Gate, persist-changes, Response Summary) that completes the `/review-github` response loop
- [../validation-methodology/references/review-reconciliation.md](../validation-methodology/references/review-reconciliation.md): shared non-GitHub review reconciliation, prosecution-depth setup, and post-fix R2 review mechanics that pair with intake after proxy judgment completes

## Gotchas

| Trigger                                                                          | Gotcha                                                                                       | Fix                                                                                             |
| -------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------- |
| Spotting a new bug while reading GitHub review comments                          | Adding it informally bypasses the prosecution → defense pipeline and breaks ledger integrity | Surface as `NEW-CRITICAL` with concrete evidence only; present to user explicitly for decision  |
| Routing implementation work before all judgment states are explicit              | Fixes applied to some findings may contradict pending rulings on others                      | All items must reach terminal state (ACCEPT / REJECT / DEFERRED-SIGNIFICANT (structural)) before any routing |

## Response Loop Completion (Terminal Step)

The ordered terminal-step sequence that makes a bare `/review-github` complete the full response loop (disposition gate, Batch Specialist Dispatch R4, post-fix targeted prosecution, CE Gate, persist-changes, and Response Summary) lives in [references/response-loop-completion.md](references/response-loop-completion.md). Load that reference once all judgment states reach terminal; accepted fixes are applied, committed, and pushed to the existing PR branch without requiring an additional user instruction.
