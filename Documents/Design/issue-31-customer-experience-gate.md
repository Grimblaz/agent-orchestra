# Design: Customer Experience Gate with Two-Track Defect Response

**Issue**: #31
**Date**: 2026-02-27
**Status**: Finalized
**Branch**: feature/issue-31-customer-experience-gate

## Summary

Introduces a formal **Customer Experience Gate (CE Gate)** as a named, first-class concept replacing the per-step Visual Verification Gate. The CE Gate verifies changes work from the customer's perspective using the right tool for the surface under change (Playwright MCP for Web UI, curl/httpie for REST/GraphQL, terminal for CLI/SDK). When defects are found, a two-track response handles both the immediate fix and any systemic process gap.

Also removes the `notify-agent-sync.yml` dispatch workflow and its CUSTOMIZATION.md documentation, as users now consume agents via VS Code file location settings.

---

## Design Decisions

| # | Decision | Choice | Rationale |
|---|----------|--------|-----------|
| D1 | CE Gate executor | Code-Conductor exercises scenarios itself using available tools | CE scenarios are natural language descriptions; no new test artifacts are created. CE Gate = "step back and use it like a customer." |
| D2 | Fix-revalidate loop budget | 2 cycles, then escalate via `ask_questions` | Consistent with review reconciliation loop budget pattern. Prevents infinite fix loops. |
| D3 | Process-Review invocation | Add Process-Review to Agent Selection table; call via `runSubagent` for Track 2 | Fits existing delegation pattern. Two-track response happens in the same flow without user intervention. |
| D4 | Visual Verification Gate | **Remove entirely.** CE Gate at end-of-PR replaces it. | CE Gate subsumes Visual Gate's purpose. Per-step regression is handled by automated tests (Tiers 2-3). One concept instead of two. |
| D5 | CE Gate vs E2E distinction | CE Gate = workflow phase (agent exercises scenarios). E2E = test type (code artifacts). Distinct concepts. | Issue-Designer's testing scope table unchanged. The E2E column indicates whether test code should be written; CE Gate is when Conductor experiences the change. |
| D6 | Project-level configuration | Optional `ce_gate` section in `.github/copilot-instructions.md`; graceful inference if missing | Explicit when available, graceful when not. Not a hard stop if absent. |
| D7 | Issue-Designer tooling check | Designer identifies customer surface, verifies tool availability, notes manual fallback | Catches tooling blockers during design, not implementation. |
| D8 | "No systemic gap" as valid outcome | Valid Track 2 outcome. Logged in PR body. No issue created. | Not every CE Gate defect has a systemic root cause. Prevents artificial findings. |
| D9 | Cross-repo issue creation | Best-effort in workflow-template repo; fallback to current repo with `process-gap-upstream` label | Doesn't block the workflow. Captures findings regardless of permissions. |
| D10 | PR body format | Add "CE Gate Result" (always) and "Process Gaps Found" (when applicable) | Integrated into canonical format. Auditable. |
| D11 | Dispatch workflow removal | Delete `notify-agent-sync.yml`; remove CUSTOMIZATION.md Section 7 | Users consume agents via VS Code file location settings — no push-based sync needed. |

---

## What the CE Gate Is

A phase that runs after the Validation Ladder and Code-Critic review, before PR creation. It answers: **"Does this change deliver the right experience for the person using this system?"**

Code-Conductor exercises CE scenarios itself — the plan describes them in natural language, and Conductor uses the right tool for the surface:

| Surface Type | Tool |
|---|---|
| Web UI / SPA | Playwright MCP: navigate, interact, verify state |
| REST / GraphQL API | Terminal: curl/httpie commands, verify responses |
| CLI tool | Terminal: invoke with realistic inputs, check stdout/exit codes |
| SDK / library | Terminal: run example invocation |
| Batch job / service | Terminal: invoke with test data, verify side effects |
| No external surface | Explicitly skip: "CE Gate not applicable — internal-only change" |

---

## Two-Track Defect Response

When the CE Gate reveals a defect:

**Track 1 — Immediate fix (in-PR)**

1. Trace root cause to the current change
2. Delegate fix to Code-Smith / Test-Writer
3. Add regression tests
4. Re-exercise the CE scenario
5. Loop budget: 2 cycles max, then escalate

**Track 2 — Systemic review**

1. Call Process-Review as subagent with defect description
2. Process-Review analyzes: what gap allowed the defect to reach CE Gate?
3. Two valid outcomes: systemic gap found (create GitHub issue) or no gap (log in PR body)

---

## Files Changed

| File | Change |
|---|---|
| `.github/workflows/notify-agent-sync.yml` | Deleted |
| `CUSTOMIZATION.md` | Section 7 "Configure Downstream Sync" removed |
| `.github/agents/Code-Conductor.agent.md` | Visual Gate removed; CE Gate section added; Agent Selection + PR body updated |
| `.github/agents/Issue-Planner.agent.md` | `[VISUAL GATE]` → `[CE GATE]`; `visual_verification` → `ce_gate` |
| `.github/agents/Issue-Designer.agent.md` | Customer surface + CE Gate readiness section added |
| `.github/agents/Process-Review.agent.md` | CE Gate trigger + Track 2 analysis format + subagent note added |
| `Documents/Design/issue-27-genericize-dispatch.md` | "Superseded" annotation added at top |

---

## Acceptance Criteria

- [x] Code-Conductor includes formal CE Gate section (surface table, scenario protocol, two-track response, loop budget)
- [x] Visual Verification Gate section fully removed from Code-Conductor
- [x] Process-Review in Code-Conductor's Agent Selection table
- [x] PR body format includes CE Gate Result and Process Gaps Found
- [x] Issue-Planner replaces `[VISUAL GATE]` with `[CE GATE]` and `visual_verification` with `ce_gate`
- [x] Issue-Designer includes customer surface identification and CE Gate readiness section
- [x] Process-Review includes CE Gate trigger, structured Track 2 output format, and subagent invocation note
- [x] `notify-agent-sync.yml` deleted
- [x] CUSTOMIZATION.md Section 7 removed, no remaining dispatch references
