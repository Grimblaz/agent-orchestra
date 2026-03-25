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
| D3 | IP askQuestions enrichment | Issue-Planner's `<rules>` block gains a rule requiring context-appropriate reasoning in all `#tool:vscode/askQuestions` calls. For plan approval, the prompt becomes a decision-card-first consent surface: a mandatory card with `Change`, `No change`, `Trade-off`, and `Areas`, plus a conditional `Execution` digest only when execution shape materially affects approval. |
| D4 | Tool boundary clarification | `edit` removed from EO, SD, and IP tools (none of these agents should be writing files — they capture design intent, summaries, and plans). Doc-Keeper's documented scope expanded to include Documents/Decisions/ authorship (creating new ADRs from issue body content) and ROADMAP.md maintenance. |

---

## Rationale

D1: Redundancy between channels is intentional — accepted trade-off (user override). `#tool:vscode/askQuestions` dialog formatting is limited; conversation text supports richer markdown. Both channels serve different invocation modes.

D2: Experience-Owner interactivity was underdocumented. The 2–3 call hub-mode budget prevents EO from becoming a bottleneck while ensuring the user can correct framing before design begins.

D3: Plan approval is the highest-leverage `#tool:vscode/askQuestions` call in the workflow — the user approves the whole plan. The dialog therefore has to stand on its own as a trustworthy consent surface: it must state what changes, what does not change, the key trade-off, and the affected areas without requiring transcript recall, while keeping execution-shape detail conditional instead of default noise.

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

## Issue #187 Additions: Plan Approval Consent Surface

### Summary

Issue #187 replaces the legacy plan-approval heuristic with a decision-card-first consent model for the Issue-Planner approval dialog. The dialog remains compact, but the compactness now comes from structured decision signal rather than from compressing the plan into step metadata and risk labels.

### Design Decisions

| ID | Decision | Details |
|----|----------|---------|
| D5 | Mandatory decision card | The plan-approval prompt must always include a compact approval card with `Change`, `No change`, `Trade-off`, and `Areas`. The first four fields are mandatory because they carry the core approval decision. |
| D6 | Conditional execution digest | `Execution` is optional and appears only when approval safety depends on execution shape, such as when the plan has more than three steps, uses parallel execution lanes, or sequencing itself is likely to change the approval decision. When present, it summarizes the plan shape rather than replaying every step. |
| D7 | Grouped areas over noisy file dumps | `Areas` should name exact files only when there are a few high-signal paths. Once file enumeration becomes noisy, the prompt must collapse to grouped workflow areas or area-level summaries rather than a raw file dump. |
| D8 | Fixed sparse-data fallback ladder | If the planner lacks exact detail, it must degrade gracefully in a fixed order: prefer exact change and scope boundary, collapse noisy files to grouped areas, derive `No change` from non-goals or unaffected surfaces, and elevate a real watchpoint when a literal trade-off is thin. If `Change` or `No change` still cannot be stated concretely, stop and clarify before asking for approval. |
| D9 | No transcript dependency | The approval dialog is the canonical consent surface inside `askQuestions`. Conversation text may elaborate, but informed approval must be possible from the dialog alone without depending on the transcript or conversation history. |

### Rationale

D5-D9: The approval dialog is where the workflow asks the user to authorize implementation. A user should be able to read the dialog and understand what will change, what will not change, the main compromise, and the affected areas without back-scrolling. The decision card makes that signal explicit; the conditional execution digest preserves approval-relevant sequencing detail without turning the dialog into a miniature transcript; grouped areas and the fallback ladder keep the prompt scannable even when exact files or exclusions are still sparse.

### Approval Information Model

The approval prompt uses a decision card. The first four fields are mandatory: `Change`, `No change`, `Trade-off`, and `Areas`.

The plan-approval prompt carries this information in priority order:

1. `Change`: one sentence describing the planned behavior or workflow change in user-relevant terms.
2. `No change`: one sentence naming the meaningful boundary, exclusion, or non-goal the user might otherwise assume is included.
3. `Trade-off`: the main compromise, watchpoint, or cost the user is accepting.
4. `Areas`: the affected files, workflow areas, or systems at a glance.
5. `Execution`: conditional and omitted otherwise.

### Approval Formatting Rules

The dialog should follow a stable labeled card shape:

- `Change:` customer-relevant behavior change
- `No change:` meaningful boundary or exclusion
- `Trade-off:` primary compromise or watchpoint
- `Areas:` exact files when few, otherwise grouped workflow areas
- `Execution:` only when needed

Formatting constraints:

- Keep the card to four mandatory lines plus one optional execution line.
- Prefer one sentence per line so the eye can scan vertically.
- Use exact file paths only when there are few of them and they materially help approval.
- Collapse noisy file sets to grouped areas or area-level summaries instead of exhaustive file dumps.
- The approval prompt must stand on its own for informed consent and must not depend on rereading the transcript.

### Approval Fallback Rules

Use this fallback order when the plan is still sparse:

1. Prefer exact behavior change and exact scope boundary when the plan supports them.
2. If exact files are noisy or undecided, collapse to grouped areas.
3. If exclusions are implicit, derive `No change` from the plan boundary, non-goals, or unaffected surfaces.
4. If there is no real trade-off but there is a meaningful watchpoint, use that watchpoint instead of inventing a trade-off.
5. If `Change` or `No change` still cannot be stated concretely, stop and clarify before asking for approval.

### Files Changed (Issue #187)

| File | Change |
|------|--------|
| `.github/agents/Issue-Planner.agent.md` | Replaced the legacy approval-summary heuristic with the decision-card-first contract, conditional execution digest rule, grouped-area preference, sparse-data fallback ladder, and clarify-before-approval behavior. |
| `Documents/Design/hub-mode-ux.md` | Synced the committed hub-mode UX design to the same approval consent model so the design doc and Issue-Planner describe the same prompt contract. |
| `.github/scripts/Tests/plan-approval-prompt-contract.Tests.ps1` | Added a semantic contract test that locks the shared approval-card fields, conditional execution-digest trigger, grouped-area fallback, no-transcript-dependency rule, and clarify-before-approval behavior without overfitting exact prose. |

---

## Issue #169 Additions: Scope Classification and Multi-Issue Bundling

### Summary

Issue #169 extended hub mode with three capabilities: a scope classification gate that determines pipeline tier before upstream agents are invoked; a multi-issue bundling protocol for concurrent issue orchestration in a single session; and a D9 checkpoint refinement that clarifies suppression semantics and extends the checkpoint to any pipeline tier.

### Design Decisions

| ID | Decision | Details |
|----|----------|---------|
| D10 | Scope Classification Gate | Before any upstream agent is called in hub mode, Code-Conductor classifies issue scope using a 5-criterion rubric. ALL five criteria must hold for abbreviated tier: (1) AC clearly defined or self-evident from issue title, (2) ≤3 files in a single domain, (3) no new user-facing behavior, (4) no cross-cutting architectural changes, (5) no CE Gate scenarios needed. Default is full pipeline when any criterion is absent or the issue is ambiguous. The user always sees both tiers as options with Code-Conductor's recommendation and may override. After Issue-Planner returns, if `escalation_recommended: true` is present in plan YAML frontmatter, Code-Conductor surfaces the `escalation_reason` via `#tool:vscode/askQuestions` and offers re-entry at the appropriate upstream phase before D9. |
| D11 | Multi-Issue Bundling Protocol | When hub mode is invoked with multiple issues (e.g., `@code-conductor issues #163 #164 #165`), Code-Conductor applies per-issue smart resume checks first, classifies each issue independently using the Scope Classification Gate rubric, and adopts the highest-scope tier for the bundle (if any issue requires full pipeline, the bundle runs full pipeline). All issue classifications are presented in a single `#tool:vscode/askQuestions` call. Shared upstream phases execute once for the bundle. Issue-Planner creates a single bundled plan named `plan-bundle-{primary}-{secondary1}-{secondaryN}.md` in session memory. At bundle D9, Code-Conductor responds to Stop / Pause by persisting durable GitHub issue comments with individual `<!-- plan-issue-{ID} -->` markers for the bundled plan and `<!-- design-issue-{ID} -->` markers for per-issue design snapshots when the latest handoff is missing or changed. Continue uses session memory only for the bundle. |
| D12 | D9 Model-Switch Checkpoint Refinement | D9 now fires for hub mode at any pipeline tier (abbreviated or full), not only full pipeline. Suppression semantics are tightened: D9 is suppressed only when the resume path already has all required prior-session upstream markers and any required durable handoff comments for the selected tier. In-session scope-based skips do not satisfy the prior-session suppression condition. For multi-issue bundles, every bundled issue must satisfy those marker and handoff-comment requirements before D9 may be suppressed. |

### Rationale

D10: Hub mode previously ran EO → SD → IP unconditionally for every issue, creating unnecessary overhead for genuinely small, well-bounded changes. The 5-criterion rubric provides a consistent, auditable classification that keeps abbreviated tier rare (all-must-hold) while preserving full pipeline as the default and ensuring user override remains always available. The escalation check after Issue-Planner ensures abbreviated-tier classification is self-correcting — Issue-Planner may discover scope that warrants full pipeline, and this surfaces before implementation begins rather than during code review.

D11: Multi-issue bundling reduces context-switching overhead when a batch of related issues is tackled in a single session. Highest-scope-wins for bundle tier is a conservative safety choice: it prevents abbreviated-tier phases from silently missing cross-issue design considerations. A single `#tool:vscode/askQuestions` for all classifications keeps the interaction proportionate — one prompt at session start, not one per issue. Keeping the bundle plan in session memory until an explicit D9 Stop / Pause preserves the fast path, while per-issue marker comments on the Stop path keep each issue independently resumable in subsequent sessions.

D12: The original D9 wording implied full-pipeline-only, which meant abbreviated-tier hub sessions proceeded from plan approval to implementation without a model-switch opportunity. Firing D9 at any tier restores the user's ability to switch models before the expensive implementation phase regardless of how upstream was classified. The tightened suppression semantics close a subtle edge case: if only some issues in a bundle had prior-session markers or durable handoff comments, D9 could be suppressed even though the session was effectively a new partial-bundle requiring user awareness before implementation.

### Files Changed (Issue #169)

| File | Change |
|------|--------|
| `.github/agents/Code-Conductor.agent.md` | Added Scope Classification Gate section with 5-criterion rubric, two-tier table, user override, and escalation check; added Multi-Issue Bundling section; updated D9 checkpoint wording to fire at any pipeline tier and tightened suppression semantics; added no-scope-exemption rule for Issue-Planner delegation |
| `.github/agents/Code-Critic.agent.md` | Added post-fix prosecution scope constraint clause and out-of-diff AC exception |
| `.github/agents/Code-Review-Response.agent.md` | Updated effort estimation language to use "high confidence" framing |
| `.github/agents/Issue-Planner.agent.md` | Added `escalation_recommended` and `escalation_reason` YAML frontmatter fields to plan output spec |

---

## Issue #196 Additions: Downstream Ownership Boundary

### Summary

Issue #196 adds a repository-ownership guardrail to hub mode so downstream orchestration can keep using shared workflow assets as guidance without silently turning a downstream issue into upstream shared-workflow maintenance. The guardrail reuses the repo's existing upstream-routing conventions and preserves the existing D9 durability contract.

### Design Decisions

| ID | Decision | Details |
|----|----------|---------|
| D13 | Exact work-class triad | Before any editing delegation or file mutation, hub mode must distinguish exactly these work classes: `downstream-owned work`, `shared read-only guidance`, and `upstream shared-workflow mutation`. The first two remain in scope for downstream issues; the third is out of scope during downstream orchestration. |
| D14 | Pre-edit ownership gate | Code-Conductor runs a pre-edit ownership gate before any editing delegation or file mutation. If the required work is already known to be `upstream shared-workflow mutation`, the run stops immediately with the visible outcome text `requires upstream issue` instead of beginning mixed-repo edits. |
| D15 | Mid-run fail-closed stop | If new scope is discovered after work has started and the newly required change is `upstream shared-workflow mutation`, the run fails closed, stops at discovery time, and emits `requires upstream issue` before any new mutation delegation. This avoids converting the downstream task into mixed-repo work. |
| D16 | Reuse existing upstream routing | The stop path reuses the existing upstream-routing conventions instead of introducing a second mechanism: link the existing upstream issue when present; otherwise, when the upstream repo can be resolved and upstream access is available, follow the existing safe-operations rules for dedup-first, priority-labeled upstream issue creation, and output capture. If the upstream repo cannot be resolved or upstream access is unavailable, create a local fallback artifact labeled `process-gap-upstream` and stop with an explicit manual upstream handoff path. Safe-operations keeps ownership of the dedup/priority/output-capture rules, and this fallback remains distinct from Process-Review's gotcha-specific `upstream-gotcha` flow. |
| D17 | Repository-aware bypass | The guardrail is repository-aware rather than file-name-based. When the active issue itself belongs to the shared workflow repo itself, shared-agent edits remain normal in-scope work. |
| D18 | External context is not permission | Pre-existing upstream dirty state is external context, not permission to continue cross-repo edits. A local upstream clone or upstream edits already present in the local clone do not authorize new upstream mutation during downstream orchestration. |
| D19 | Preserve D9 durability ownership | The new ownership gate does not change plan/design handoff durability. D9 remains the only durable execution-handoff writer; Continue remains session-memory-only, and Issue-Planner still stops at session-memory handoff. |

### Rationale

D13-D15: The trust failure in issue #196 was not caused by shared guidance reads; it was caused by mutation scope widening without an explicit boundary check. Requiring both the pre-edit ownership gate and the mid-run fail-closed stop fixes that at the point where scope can expand.

D16: Reusing the existing upstream-routing path keeps the workflow legible. The repo already has conventions for `copilot-orchestra-repo` resolution, dedup-first issue creation, priority labeling, output capture, and the local `process-gap-upstream` fallback when the upstream repo cannot be resolved or upstream access is unavailable. This ownership-boundary fallback is intentionally separate from Process-Review's gotcha-specific `upstream-gotcha` flow, so the stop path stays deterministic instead of collapsing two mechanisms into one.

D17-D18: Repository awareness avoids false positives for legitimate shared-workflow maintenance, while the external-context rule closes the loophole where an already-dirty local upstream clone could be misread as permission to continue cross-repo edits.

D19: The issue is about repository ownership boundaries, not handoff persistence. Keeping D9 semantics unchanged preserves the existing latest-comment-wins durability contract and avoids reopening the planner-vs-conductor ownership boundary.

### Files Changed (Issue #196)

| File | Change |
|------|--------|
| `.github/agents/Code-Conductor.agent.md` | Added the downstream ownership boundary contract: exact work-class triad, pre-edit ownership gate, mid-run fail-closed stop, repository-aware bypass, external-context rule, and explicit reuse of existing upstream-routing conventions while preserving D9 semantics |
| `Documents/Design/hub-mode-ux.md` | Added the synced design rationale and decisions for the downstream ownership boundary so the committed design doc matches Code-Conductor's wording |
