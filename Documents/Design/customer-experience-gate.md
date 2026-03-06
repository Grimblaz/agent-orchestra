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

---

## Intent Verification (Issue #72 Extension)

Issue #72 extended the CE Gate to evaluate **intent** as a second dimension alongside functional verification. A change can pass all functional scenarios while still missing the design intent described in the issue.

### What Intent Verification Adds

Code-Conductor now judges two dimensions after exercising scenarios:

1. **Functional** — does each scenario behave as expected from a customer perspective? (unchanged)
2. **Intent match** — does the implementation achieve the design intent the issue described?

### Intent Match Levels

| Level | Criteria |
|-------|----------|
| **strong** | Behavior matches the design, user-facing language is clear and specific, flow follows the intended path |
| **partial** | Behavior works but user path diverges from intent; feedback is generic where the design specified contextual messaging; or edge case handling is rough |
| **weak** | Feature works but is difficult to discover or use without documentation; or error states show technical details instead of user guidance; or flow contradicts the stated user experience |

**Default is `strong`** — only downgrade when a specific, articulable criterion is violated. "Feels off" is not sufficient evidence.

### Updated Markers

The passing markers now include an intent match level:

- `✅ CE Gate passed — intent match: strong` — all scenarios pass, design intent fully achieved
- `✅ CE Gate passed — intent match: partial` — functional pass; intent partially achieved (in-PR fix by default)
- `✅ CE Gate passed — intent match: weak` — functional pass; intent not met (in-PR fix by default)
- `✅ CE Gate passed after fix — intent match: {strong|partial|weak}` — defects found and resolved within loop budget

### Intent Deficiency Routing

`partial` and `weak` intent matches are ✅ passes (not failures) but do require action. They route through the existing Two-Track Defect Response:

- **Track 1**: By default, route to Code-Smith with the specific rubric criterion violated and the design intent reference. When the deficiency would require a new design decision to define a fix (e.g., the core interaction model contradicts the design intent and cannot be corrected by a targeted code change), Code-Conductor may defer to a follow-up issue instead — judgment call, default is fix in-PR.
- **Track 2**: Always invoke Process-Review, including when taking the follow-up-issue path. Track 2 for intent deficiencies uses the `intent mismatch` classification option.

### Surface-Specific Verification

Intent criteria are surface-dependent. A surface-specific table in Code-Conductor identifies *what* to evaluate per surface type; the rubric translates those observations into the strong/partial/weak level.

### Design Decisions (Issue #72)

| # | Decision | Choice | Rationale |
|---|----------|--------|-----------|
| D12 | Intent as second CE Gate dimension | Rate intent match (strong/partial/weak) alongside functional pass/fail | Functional pass alone does not guarantee the right user experience; intent provides a direct check against design goals |
| D13 | Default intent level | `strong` unless a specific criterion is violated | Prevents speculative downgrades; requires articulable evidence before emitting partial/weak |
| D14 | Intent deficiency routing | Through existing Two-Track (Track 1 in-PR default; Track 2 always) | Reuses the same escalation and systemic-analysis path; no new routing mechanism needed |
| D15 | `Design Intent` field in `[CE GATE]` plan step | Code-Conductor reads it as the primary intent reference (supersedes re-reading the full issue body) | Issue-Planner already distills the intent into the plan step; Code-Conductor should consume it directly |

### Files Changed (Issue #72)

| File | Change |
|---|---|
| `.github/agents/Code-Conductor.agent.md` | Intent Match Rubric + Surface-Specific Intent Verification table added; markers updated with intent match levels; intent deficiency routing added to Two-Track; Step 2 updated to read `Design Intent` field from plan step first |
| `.github/agents/Process-Review.agent.md` | `intent mismatch` added as third Classification option in CE Gate Defect Analysis structured output |
| `.github/agents/Issue-Planner.agent.md` | `[CE GATE]` step template updated with `Design Intent` field |
| `.claude/commands/implement.md` | `after fix` marker variant added to CE Gate section |
