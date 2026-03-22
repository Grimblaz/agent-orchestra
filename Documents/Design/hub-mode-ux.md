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

---

## Issue #169 Additions: Scope Classification and Multi-Issue Bundling

### Summary

Issue #169 extended hub mode with three capabilities: a scope classification gate that determines pipeline tier before upstream agents are invoked; a multi-issue bundling protocol for concurrent issue orchestration in a single session; and a D9 checkpoint refinement that clarifies suppression semantics and extends the checkpoint to any pipeline tier.

### Design Decisions

| ID | Decision | Details |
|----|----------|---------|
| D5 | Scope Classification Gate | Before any upstream agent is called in hub mode, Code-Conductor classifies issue scope using a 5-criterion rubric. ALL five criteria must hold for abbreviated tier: (1) AC clearly defined or self-evident from issue title, (2) ≤3 files in a single domain, (3) no new user-facing behavior, (4) no cross-cutting architectural changes, (5) no CE Gate scenarios needed. Default is full pipeline when any criterion is absent or the issue is ambiguous. The user always sees both tiers as options with Code-Conductor's recommendation and may override. After Issue-Planner returns, if `escalation_recommended: true` is present in plan YAML frontmatter, Code-Conductor surfaces the `escalation_reason` via `#tool:vscode/askQuestions` and offers re-entry at the appropriate upstream phase before D9. |
| D6 | Multi-Issue Bundling Protocol | When hub mode is invoked with multiple issues (e.g., `@code-conductor issues #163 #164 #165`), Code-Conductor applies per-issue smart resume checks first, classifies each issue independently using the Scope Classification Gate rubric, and adopts the highest-scope tier for the bundle (if any issue requires full pipeline, the bundle runs full pipeline). All issue classifications are presented in a single `#tool:vscode/askQuestions` call. Shared upstream phases execute once for the bundle. Issue-Planner creates a single bundled plan named `plan-bundle-{primary}-{secondary1}-{secondaryN}.md`, persisted to session memory and posted as a GitHub issue comment to each bundled issue with individual `<!-- plan-issue-{ID} -->` markers. D9 suppression for a bundle requires ALL tier-required markers for ALL bundled issues to have been completed in prior sessions. |
| D7 | D9 Model-Switch Checkpoint Refinement | D9 now fires for hub mode at any pipeline tier (abbreviated or full), not only full pipeline. Suppression semantics are tightened: D9 is suppressed only when ALL applicable upstream phase markers were completed in prior sessions (abbreviated tier: `<!-- plan-issue-{ID} -->` only; full tier: all three phase completion markers — EO, SD, and plan). In-session scope-based skips do not satisfy the prior-session suppression condition. For multi-issue bundles, ALL markers for ALL bundled issues must be prior-session complete before D9 may be suppressed. |

### Rationale

D5: Hub mode previously ran EO → SD → IP unconditionally for every issue, creating unnecessary overhead for genuinely small, well-bounded changes. The 5-criterion rubric provides a consistent, auditable classification that keeps abbreviated tier rare (all-must-hold) while preserving full pipeline as the default and ensuring user override remains always available. The escalation check after Issue-Planner ensures abbreviated-tier classification is self-correcting — Issue-Planner may discover scope that warrants full pipeline, and this surfaces before implementation begins rather than during code review.

D6: Multi-issue bundling reduces context-switching overhead when a batch of related issues is tackled in a single session. Highest-scope-wins for bundle tier is a conservative safety choice: it prevents abbreviated-tier phases from silently missing cross-issue design considerations. A single `#tool:vscode/askQuestions` for all classifications keeps the interaction proportionate — one prompt at session start, not one per issue. Per-issue markers and plan comment distribution to each issue ensure each remains independently resumable in subsequent sessions.

D7: The original D9 wording implied full-pipeline-only, which meant abbreviated-tier hub sessions proceeded from plan approval to implementation without a model-switch opportunity. Firing D9 at any tier restores the user's ability to switch models before the expensive implementation phase regardless of how upstream was classified. The tightened suppression semantics close a subtle edge case: if only some issues in a bundle had prior-session markers, D9 was suppressible even though the session was effectively a new partial-bundle requiring user awareness before implementation.

### Files Changed (Issue #169)

| File | Change |
|------|--------|
| `.github/agents/Code-Conductor.agent.md` | Added Scope Classification Gate section with 5-criterion rubric, two-tier table, user override, and escalation check; added Multi-Issue Bundling section; updated D9 checkpoint wording to fire at any pipeline tier and tightened suppression semantics; added no-scope-exemption rule for Issue-Planner delegation |
| `.github/agents/Code-Critic.agent.md` | Added post-fix prosecution scope constraint clause and out-of-diff AC exception |
| `.github/agents/Code-Review-Response.agent.md` | Updated effort estimation language to use "high confidence" framing |
| `.github/agents/Issue-Planner.agent.md` | Added `escalation_recommended` and `escalation_reason` YAML frontmatter fields to plan output spec |
