# Design: Customer Experience Gate

## Summary

The Customer Experience Gate (CE Gate) is a named, first-class workflow phase that runs after the Validation Ladder and Code-Critic review, before PR creation. It answers: **"Does this change deliver the right experience for the person using this system?"** Code-Conductor exercises CE scenarios itself using the right tool for the surface under change. When defects are found, a two-track response handles both the immediate fix and any systemic process gap.

This design also retired the `notify-agent-sync.yml` dispatch workflow, as agents are now consumed via VS Code file location settings rather than push-based sync.

---

## Design Decisions

| # | Decision | Choice | Rationale |
|---|----------|--------|-----------|
| D1 | CE Gate executor | Code-Conductor exercises scenarios itself | CE scenarios are natural language descriptions; no new test artifacts created. CE Gate = "step back and use it like a customer." |
| D2 | Fix-revalidate loop budget | 2 cycles, then escalate via `vscode/askQuestions` | Consistent with review reconciliation loop budget pattern; prevents infinite fix loops |
| D3 | Process-Review invocation | Add to Agent Selection table; call via subagent for Track 2 | Fits existing delegation pattern; two-track response happens in the same flow without user intervention |
| D4 | Visual Verification Gate | **Remove entirely.** CE Gate at end-of-PR replaces it. | CE Gate subsumes Visual Gate's purpose; per-step regression handled by automated tests (Tiers 2–3); one concept instead of two |
| D5 | CE Gate vs E2E distinction | CE Gate = workflow phase (agent exercises scenarios). E2E = test type (code artifacts). Distinct concepts. | Issue-Designer's testing scope table unchanged; the E2E column indicates whether test code should be written; CE Gate is when Conductor experiences the change |
| D6 | Project-level configuration | Optional `ce_gate` section in `copilot-instructions.md`; graceful inference if missing | Explicit when available; graceful when not; not a hard stop if absent |
| D7 | Issue-Designer tooling check | Designer identifies customer surface, verifies tool availability, notes manual fallback | Catches tooling blockers during design, not implementation |
| D8 | "No systemic gap" as valid outcome | Valid Track 2 outcome; logged in PR body; no issue created | Not every CE Gate defect has a systemic root cause; prevents artificial findings |
| D9 | Cross-repo issue creation | Best-effort in workflow-template repo; fallback to current repo with `process-gap-upstream` label | Does not block the workflow; captures findings regardless of permissions |
| D10 | PR body format | Add "CE Gate Result" (always) and "Process Gaps Found" (when applicable) | Integrated into canonical format; auditable |
| D11 | Dispatch workflow removal | Delete `notify-agent-sync.yml`; remove CUSTOMIZATION.md Section 7 | Users consume agents via VS Code file location settings — no push-based sync needed |

---

## What the CE Gate Is

A phase that runs after the Validation Ladder and Code-Critic review, before PR creation. Code-Conductor exercises CE scenarios itself — the plan describes them in natural language, and Conductor uses the right tool for the surface:

| Surface Type | Tool |
|---|---|
| Web UI / SPA | Native browser tools (`openBrowserPage`, `screenshotPage`) — primary; Playwright MCP as fallback |
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
5. Loop budget: 2 cycles max, then escalate via `vscode/askQuestions`

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
