# Design: Experience-Owner Agent

## Summary

The Experience-Owner agent bookends the pipeline with a customer-experience lens. It has two phases: an **upstream framing phase** (before design begins) and a **downstream evidence-capture phase** (at CE Gate, delegated by Code-Conductor). This design introduces Experience-Owner as a seventh user-facing agent and extracts CE Gate scenario definition and execution from Solution-Designer and Code-Conductor respectively.

---

## Design Decisions

| # | Decision | Choice | Rationale |
|---|----------|--------|-----------|
| D1 | CE scenario ownership | Experience-Owner defines and exercises CE scenarios | Separates customer-experience expertise from technical design (Solution-Designer) and implementation orchestration (Code-Conductor); enables upstream scenario definition before code exists |
| D2 | CE Gate execution model | Code-Conductor delegates to Experience-Owner subagent | Orchestration remains with Code-Conductor; execution expertise moves to Experience-Owner; preserves CE Gate architecture and PR body format |
| D3 | Upstream phase gating | Optional — user invokes `@Experience-Owner` or `/experience` before design | Framing is high-value when starting new features; skip-safe for issues with existing customer framing |
| D4 | Downstream evidence handoff | Experience-Owner captures evidence and passes to Code-Critic | Evidence-capture and prosecution remain separate (D5 of CE Gate design — fox-guarding-henhouse prevention) |
| D5 | Solution-Designer scope | Remove customer-experience content; narrow to technical design only | Single responsibility: design space exploration and decision documentation |
| D6 | Graceful degradation | Experience-Owner emits `⚠️ CE Gate evidence capture blocked` if environment unavailable | Consistent with CE Gate graceful degradation pattern; Code-Conductor proceeds with available evidence |
| D7 | Prompt file | Add `experience.prompt.md` with `agent: Experience-Owner` | Consistent with `/design` → `design.prompt.md` pattern; enables `/experience` slash command |
| D8 | Agent count | 7 user-facing (was 6) | Experience-Owner is user-invocable; Solution-Designer replaces Issue-Designer at same user-facing count position |
| D9 | Hub Mode + D9 Checkpoint | Code-Conductor gains Smart Resume markers and a D9 pause checkpoint after upstream phases complete | Prevents full upstream re-execution on session resume; user can pause between customer framing and implementation |
| D10 | Collaboration Pattern for upstream interactivity | Add dedicated `### Collaboration Pattern` subsection in Upstream Phase; hub-mode budget of 2–3 `#tool:vscode/askQuestions` calls; checkpoints at scope ambiguity, key framing decisions, and CE Gate scenario drafting confirmation | Interactivity guidance was underdocumented; explicit budget prevents EO from becoming a hub-mode bottleneck |

---

## Upstream Phase

Experience-Owner frames the customer problem before design begins:

1. **Customer Problem Statement** — Who is affected? What is the gap? What outcome do they need?
2. **User Journeys** — 2–4 journeys from the customer's perspective (not implementation steps)
3. **CE Gate Scenarios** — Functional and Intent scenario types; identifies customer surface and tool availability
4. **Design Intent Reference** — distills the CE Gate `Design Intent` field for the `[CE GATE]` plan step
5. **Surface Readiness Assessment** — Identifies which tools are available for the surface under change
6. **Persists output** — Posts a comment to the GitHub issue with the `<!-- experience-owner-complete-{ID} -->` marker
7. **Interactivity** — Decision-by-decision confirmation using `#tool:vscode/askQuestions`; hub-mode budget 2–3 calls. See `### Collaboration Pattern` in the agent file.

---

## Downstream Phase (CE Gate Evidence Capture)

Invoked by Code-Conductor as a subagent during the CE Gate:

1. Reads `<!-- experience-owner-complete-{ID} -->` from issue comments
2. Identifies surface and exercises each scenario using the appropriate tool
3. Captures evidence (screenshots, API responses, CLI output)
4. Returns structured evidence to Code-Conductor
5. Code-Conductor passes evidence to Code-Critic for CE prosecution

---

## Pipeline Integration

```text
@Experience-Owner (upstream) → @Solution-Designer → @Issue-Planner → @Code-Conductor → PR
                                                                              ↓
                                                          Code-Conductor delegates CE Gate
                                                          evidence capture to:
                                                          @Experience-Owner (downstream)
                                                                              ↓
                                                          @Code-Critic (CE prosecution)
                                                          → defense → judge
```

---

## Files Changed

| File | Change |
|------|--------|
| `.github/agents/Experience-Owner.agent.md` | New agent — upstream framing + downstream CE evidence capture |
| `.github/agents/Solution-Designer.agent.md` | Renamed from Issue-Designer; CE content removed; scope narrowed to technical design |
| `.github/agents/Code-Conductor.agent.md` | Hub Mode + Smart Resume + D9 Checkpoint added; CE Gate Scenario Exercise Protocol delegates to Experience-Owner |
| `.github/agents/Code-Critic.agent.md` | Issue-Designer → Solution-Designer; CE evidence source → Experience-Owner |
| `.github/agents/Issue-Planner.agent.md` | CE Gate readiness source → Experience-Owner; graceful degradation added |
| `.github/agents/Research-Agent.agent.md` | Handoff → Solution-Designer |
| `.github/agents/Process-Review.agent.md` | CE mismatch → Experience-Owner |
| `.github/agents/Doc-Keeper.agent.md` | Cross-reference updated |
| `.github/prompts/experience.prompt.md` | New slash command: `/experience` → Experience-Owner |
| `.github/prompts/design.prompt.md` | agent: Solution-Designer |
| `.github/copilot-instructions.md` | Pipeline diagram + agent count + CE review description updated |
| `README.md` | Plugin count + agent table + pipeline + Workflow updated |
| `.github/architecture-rules.md` | Agent counts + Issue-Designer retired-name grep added |
| `CONTRIBUTING.md` | User-facing count 6→7 |
| `CUSTOMIZATION.md` | 13→14 agents |
