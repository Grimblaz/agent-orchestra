---
name: code-review-intake
description: Deterministic GitHub review intake workflow with ledger-based judgment. Use when processing GitHub code review comments, reconciling Code-Critic findings, or running GitHub review intake mode. DO NOT USE FOR: pre-PR readiness checks (use verification-before-completion) or post-merge cleanup (use post-pr-review).
---

## When to Use

Activate this skill when the request includes any of the following trigger phrases:

- `github review`
- `review github`
- `cr review`

## Purpose

Provide a deterministic intake and judgment workflow for GitHub-originated review feedback before implementation work begins.

## GitHub Review Mode (Proxy Prosecution Pipeline)

1. Ingest all review items from GitHub (threads, top-level comments, review summaries).
2. Build a finding ledger where each item maps to its GitHub comment/review ID.
3. **Proxy prosecution**: Call Code-Critic with `"Score and represent GitHub review"` marker. Code-Critic validates and scores each GitHub comment (critical/high→10 pts, medium→5 pts, low→1 pt). Output: scored prosecution ledger.
4. **Defense pass**: Call Code-Critic with `"Use defense review perspectives"` marker, passing the prosecution ledger.
5. **Judge pass**: Call Code-Review-Response with both prosecution ledger and defense report. Judge rules final and emits score summary.

## Hard Guardrail

In GitHub Review Mode, do not add net-new findings outside the ingested GitHub ledger.

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

## Convergence

The proxy prosecution pipeline is single-shot: prosecution → defense → judge, with no rebuttal rounds. Judge rules final on all items. Unresolved items at low judge confidence are surfaced for user scoring via GitHub issue comment (async, non-blocking).
