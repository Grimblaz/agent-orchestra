# Code Review Intake Instructions

## Purpose

Provide a deterministic intake and adjudication workflow for GitHub-originated review feedback before implementation work begins.

## Trigger

Use this workflow when the request includes:

- `github review`
- `review github`
- `cr review`

## GitHub Review Mode

1. Ingest all review items from GitHub (threads, top-level comments, review summaries).
2. Build a finding ledger where each item maps to its GitHub comment/review ID.
3. Call Code-Critic to evaluate ledger items only.
4. Call Code-Review-Response to disposition the same ledger items.
5. Run rebuttal rounds only on disputed ledger items until convergence or loop-budget escalation.

## Hard Guardrail

In GitHub Review Mode, do not add net-new findings outside the ingested GitHub ledger.

### Safety Exception

A new item may be added only for a critical correctness/security blocker discovered during verification. It must:

- Be tagged `NEW-CRITICAL`
- Include concrete evidence
- Be explicitly surfaced to the user

## Adjudication Guardrail

Adjudication is evidence-first and deterministic:

- Every accepted/rejected/deferred item cites code, test output, architecture constraints, or issue AC evidence.
- Preference-only comments without evidence are rejected by default.
- Conflicting evidence keeps an item in disputed state until resolved or escalated.
- Do not route implementation work until adjudication states are explicit.

## Convergence Criteria

Converged when all items are in a terminal state:

- ✅ ACCEPT
- 📋 DEFERRED-SIGNIFICANT
- ❌ REJECT

Plus:

- No unresolved evidence disputes remain.
- User has visibility before any authority-boundary decision gate.

## Loop Budget

Maximum 3 reconciliation rounds. If disputes remain, escalate via `vscode/askQuestions` with recommended options.
