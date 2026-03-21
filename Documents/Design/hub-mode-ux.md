# Design: Hub Mode UX — askQuestions Enrichment

## Summary

This design adds structured interactivity and reasoning-channel enrichment across four agents to improve hub-mode usability. In hub mode, Code-Conductor orchestrates Experience-Owner, Solution-Designer, and Issue-Planner in sequence; the user interacts primarily through `#tool:vscode/askQuestions` dialogs. Without reasoning embedded in the dialog options, hub-mode users must read conversation history to understand trade-offs — creating friction in the highest-value workflow path.

---

## Problem

`#tool:vscode/askQuestions` dialogs in hub mode show option labels and descriptions but do not guarantee full reasoning is visible without scrolling through conversation history. Agents were instructed to present reasoning in conversation text "before the call," but option descriptions were left sparse. In hub mode, the user may not see the conversation text if the dialog appears above a long context window.

Additionally, Experience-Owner had no structured interactivity guidance for the upstream framing phase — it relied on implicit agent judgment for when to check in with the user.

---

## Design Decisions

| ID | Decision | Details |
|----|----------|---------|
| D1 | Full reasoning in both channels | Every `#tool:vscode/askQuestions` call presents full reasoning (pros, cons, trade-offs) in conversation text before the call AND embeds full reasoning in the recommended option's description. Alternative options get 1-line summaries. Conversation text is the primary reading experience in direct invocation; descriptions ensure reasoning is visible in hub-mode dialogs. ~4K char soft cap on total option description content. |
| D2 | EO Collaboration Pattern | Experience-Owner's Upstream Phase gains a `### Collaboration Pattern` section defining principles for when to pause vs. proceed autonomously, example checkpoints, and hub-mode budget (target 2–3 calls). |
| D3 | IP askQuestions enrichment | Issue-Planner's `<rules>` block gains a rule requiring context-appropriate reasoning in all `#tool:vscode/askQuestions` calls: plan approval includes step count, 1-line per-step summaries (~80 chars each), and top-3 risks (~3K total cap). |
| D4 | Tool boundary clarification | `edit` removed from EO, SD, and IP tools (none of these agents should be writing files — they capture design intent, summaries, and plans). Doc-Keeper's documented scope expanded to include Documents/Decisions/ authorship (creating new ADRs from issue body content) and ROADMAP.md maintenance. |

---

## Rationale

D1: Redundancy between channels is intentional — accepted trade-off (user override). `#tool:vscode/askQuestions` dialog formatting is limited; conversation text supports richer markdown. Both channels serve different invocation modes.

D2: Experience-Owner interactivity was underdocumented. The 2–3 call hub-mode budget prevents EO from becoming a bottleneck while ensuring the user can correct framing before design begins.

D3: Plan approval is the highest-leverage `#tool:vscode/askQuestions` call in the workflow — the user approves the whole plan. Embedding step summaries and top risks makes this a genuine informed decision rather than a context-blind approve/reject.

D4: Tool misrepresentation — if an agent's body describes capabilities that `tools:` doesn't declare, it misleads the model. EO/SD/IP don't need edit for their defined roles; DK is the designated file-editing agent.

---

## Files Changed

| File | Change |
|------|--------|
| `.github/agents/Experience-Owner.agent.md` | Removed `edit` from tools; added "Reasoning everywhere" QP bullet; added `### Collaboration Pattern` section |
| `.github/agents/Solution-Designer.agent.md` | Removed `edit` from tools; added "Reasoning everywhere" QP bullet; updated Collaboration Pattern step 3 to lead with conversation text; updated Boundaries DON'T list; updated Document Decisions and Documentation Maintenance sections |
| `.github/agents/Issue-Planner.agent.md` | Removed `edit` from tools; added 4th `<rules>` bullet for askQuestions enrichment |
| `.github/agents/Doc-Keeper.agent.md` | Added Documents/Decisions/ and ROADMAP.md to Documentation Maintenance Responsibilities; updated Core Responsibilities item 3 and Update Process step 4 to include CREATE action; removed SD from cross-reference |
