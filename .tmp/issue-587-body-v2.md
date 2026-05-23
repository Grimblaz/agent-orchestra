## Problem Statement (Customer)

When I run `/plan` on a non-trivial GitHub issue or `/orchestra:review` on a PR, some of my parallel adversarial passes halt mid-batch with an `environment-divergence` finding even though I haven't touched the working tree. The retry path recovers and I still get a usable ledger, but each spurious halt costs a full subagent dispatch (~20K tokens). When I open the contract that's supposed to govern this — `skills/subagent-env-handshake/SKILL.md` § Parallel-batch dispatch — I find a load-bearing assertion ("no tree mutation can occur between members of one parallel tool-use block") that the live evidence directly contradicts. I want either the contract to honestly describe what really happens, or the underlying subagent behavior tightened so the contract's claim holds.

## Customer Segments

| Segment | Who | What they experience today |
| --- | --- | --- |
| **Planner** | Anyone running `/plan` on a non-trivial issue | 1-of-3 or 2-of-3 prosecution passes halt with ND-2, partial-pass-recovery absorbs the cost, but extra dispatches are visible in the run output. |
| **Reviewer** | Anyone running `/orchestra:review` (full pipeline) on a PR | Prosecution × 3 batch behaves the same way — halts + retries inside an otherwise-clean review run. |
| **Contract reader (maintainer)** | Anyone reading the SKILL.md to understand the handshake guarantees | Encounters a load-bearing rationale that doesn't match the live behavior, eroding trust in adjacent contract claims that *are* correct. |

## Customer Journeys

### Current journey (Planner)

1. Run `/plan 557` against a non-trivial issue.
2. Parent captures handshake state with a single dirty fingerprint and dispatches 3 prosecution passes in one parallel tool-use block.
3. Pass 2 returns a 12-finding ledger; Pass 1 and Pass 3 each halt with ND-2 because the dirty fingerprint they observe differs from the parent's captured value.
4. Retry path fires, the retries run on a cleaner tree, both succeed.
5. Final output is useful, but two extra subagent dispatches were spent on the halt and the run output carries noise that suggests something is wrong.

### Current journey (Contract reader)

1. Open `skills/subagent-env-handshake/SKILL.md` to confirm the handshake guarantees before relying on them in a new dispatch site.
2. Read the Parallel-batch dispatch section.
3. Notice the "no tree mutation can occur between members of one parallel tool-use block" claim.
4. Cross-reference against live `/plan` evidence: see three different dirty fingerprints observed for the same captured handshake.
5. Conclude the contract's load-bearing rationale is wrong; lose confidence that other parts of the contract reflect reality.

### Target journey

The Planner runs `/plan` or `/orchestra:review` and either (a) the parallel batch completes without spurious ND-2 halts, or (b) when halts do occur, the contract honestly describes the failure mode and recovery as part of the documented behavior — not as an anomaly that contradicts the stated guarantee. The Contract reader opens the SKILL.md and finds load-bearing claims that match observable behavior.

### Edge journey

A maintainer wires a new subagent dispatch site against the current contract's load-bearing claim, ships the dispatch, then encounters ND-2 halts that the contract said couldn't happen. They spend time debugging assuming their dispatch logic is wrong before discovering the contract premise is the actual gap.

## Scenarios

### S1 — Planner sees a clean parallel-batch run (Functional)

- **Given** the working tree is clean and `/plan` is invoked on a non-trivial issue
- **When** Code-Conductor dispatches the 3-pass prosecution batch in one parallel tool-use block
- **Then** all three prosecution passes return ledgers without ND-2 environment-divergence halts attributable to sibling subagent tree mutations
- **Customer outcome**: no extra retry cost; planner sees a clean 3-of-3 result.

### S2 — Contract reader can trust the parallel-batch rationale (Functional)

- **Given** a maintainer is reading `skills/subagent-env-handshake/SKILL.md` § Parallel-batch dispatch
- **When** they read the load-bearing rationale for the single-capture-per-batch policy
- **Then** the stated rationale is consistent with the live behavior of parallel subagent dispatches under `workspace_mode: shared`
- **Customer outcome**: contract claim is verifiable; reader can rely on it when extending the handshake to new dispatch sites.

### S3 — Maintainer trust in adjacent contract claims is preserved (Intent)

- **Given** a maintainer reading the handshake contract has observed live behavior in `/plan` or `/orchestra:review`
- **When** they finish reading the Parallel-batch dispatch section
- **Then** they leave with the impression that the contract honestly describes both the optimization and its failure modes
- **Customer outcome**: trust in adjacent contract claims (per-dispatch policy, capture ordering, ND-2 finding template) is preserved because no section reads as wishful thinking.

### S4 — Planner experiences halt-then-recover without alarm (Intent)

- **Given** a planner is running `/plan` and observes an ND-2 halt during the parallel batch
- **When** they read the run output describing the halt and retry
- **Then** the output language frames the halt as a known recovery path, not as an unexpected contract violation
- **Customer outcome**: the planner does not interpret the halt as a defect that needs filing; they trust the recovery and continue.

## Design Intent

**Honest contract over optimistic contract.** When the parallel-batch policy makes a load-bearing claim, that claim must match what shared-workspace subagents actually do. Spurious ND-2 halts during parallel batches under `workspace_mode: shared` are a real failure mode driven by subagent-side tree mutations; the contract must either prevent the mutations (subagent-side discipline) or acknowledge the failure mode and document the recovery path as the load-bearing guarantee. The customer's trust in the contract is the primary asset to protect — the per-run token cost is secondary.

**Out of scope for this issue** (preserved from the original engineering write-up):

- Removing the parallel-batch optimization itself.
- Removing `workspace_mode: shared` (Claude Code default).
- Designing `workspace_mode: worktree` v2 schema (reserved for a separate issue).
- Fixing the editor-parallel dispatch gap (Code-Smith ↔ Test-Writer, Doc-Keeper batches) — acknowledged as a known gap pending v2 worktree mode; tracked as follow-up issue #606.

## Surface & CE Gate Readiness

| Surface | Applies? | CE Gate readiness | Notes |
| --- | --- | --- | --- |
| `documentation` (SKILL.md prose) | ✅ Yes | Ready — verifiable by reading the updated SKILL.md text against the customer-facing rationale claim. | Primary surface. S3 (maintainer trust) exercised here. |
| `behavioral` (parallel-batch dispatch in `/plan`, `/orchestra:review`, `/design` 3-pass challenge) | ✅ Yes | Baseline-comparable — issue body captures live evidence of 2-of-3 halts on a near-clean tree; a post-change run on a clean tree provides the comparison. The /design 3-pass challenge for THIS issue itself returned 3-of-3 cleanly after including the dispatch-prompt directive — early empirical validation. | Exercised by S1 and S4. |
| `cli` | ✅ Yes | Ready — Claude slash-command surface (\`/plan\`, \`/orchestra:review\`) qualify as the CLI surface for the M1 functional scenario | Exercised by M1 in s8. |
| `browser` | ❌ No | n/a | No browser surface. |
| `canvas` | ❌ No | n/a | No canvas surface. |
| `api` | ❌ No | n/a | No HTTP/API surface. |

**Hub/consumer classification**: stays in hub. `skills/subagent-env-handshake/` is a Claude Code-only skill (`scope: claude-only`) governing the Claude Agent-tool dispatch model. No consumer-repo artifact applies; no language-specific content is involved.

---

## Technical Design (Solution-Designer)

### Recommended direction: A' + B' (revised after 3-pass adversarial design challenge)

The original `A + B (scoped)` direction approved by the maintainer was revised after the design-challenge prosecution surfaced four high-severity findings (cross-tool placement, advisory enforcement, parallel-execution lane scope, S4 framing). The revised direction below incorporates each.

### A'.1 — Canonical discipline in the SKILL.md (not agent bodies)

Add a new section to `skills/subagent-env-handshake/SKILL.md` titled `## Subagent working-tree discipline (under workspace_mode: shared)`, sibling to the existing `## Parallel-batch dispatch` section. Content:

- Subagents dispatched in parallel batches under `workspace_mode: shared` MUST NOT write to the parent working tree during analysis.
- Reads (`git`, `Read` tool, `Bash` `cat`/`grep`/`gh`) are permitted.
- Scratch space goes outside the repo root: `mktemp -d` on POSIX, `$env:TEMP/$(New-Guid)` on Windows. Do not redirect `Bash` output to files inside the repo (no `> output.txt` with bare filenames).
- The discipline is `scope: claude-only` — Copilot's dispatch model shares the workspace with different tool bindings and is exempt per the SKILL's existing Copilot-exemption clause.
- Under `workspace_mode: worktree` (v2, reserved) the discipline is unnecessary because each subagent gets an isolated copy; the section is scoped explicitly to `shared` for forward-compatibility.

**Why the SKILL.md, not the agent bodies**: per the design-challenge Cluster A finding, the discipline is Claude-only methodology. Landing it in cross-tool `agents/*.agent.md` bodies that Copilot also loads would put Claude-only methodology into Copilot's view (and the rationale would reference Claude-only Step 0). Authoring the discipline in the already-claude-only SKILL.md respects the scope boundary and keeps one source of truth.

### A'.2 — Dispatch-prompt directive at each parallel-batch site

Prepend a one-paragraph directive to each parallel-batch `Agent` dispatch instructing the dispatched subagent to follow the SKILL.md § Subagent working-tree discipline section. Sites:

- `commands/plan.md` — the 3-pass Code-Critic prosecution batch (current lines ~50–55).
- `commands/orchestra-review.md` — the 3-pass prosecution batch (current line ~34).
- `skills/design-exploration/SKILL.md` — the 3-pass design-challenge prosecution batch (or the calling site in `agents/Solution-Designer.agent.md`).

**Why a dispatch-time directive in addition to body prose**: the design-challenge prosecution Pass 3 noted that dispatch-time directives are structural enforcement (the directive is read at dispatch entry, before any tool call), while body-prose discipline is internalized later. The 3 Code-Critic passes dispatched in *this very design-challenge prosecution* each carried the directive in their prompts and all three returned without ND-2 halts — live empirical validation that the directive lever works.

### A'.3 — Enumerate parallel-batch dispatch sites in SKILL.md with classification

Add a subsection to SKILL.md § Parallel-batch dispatch that enumerates the known parallel-batch dispatch sites and classifies each:

**In-scope (analysis-only; discipline applies)**:

- `commands/plan.md` — Code-Critic prosecution × 3
- `commands/orchestra-review.md` — Code-Critic prosecution × 3
- `skills/design-exploration/SKILL.md` — Code-Critic design-challenge × 3

**Out-of-scope (editor-required; governed by `skills/parallel-execution/SKILL.md` Requirement Contract coordination)**:

- Code-Conductor `Execution Mode: parallel` — Code-Smith ↔ Test-Writer parallel dispatch (both MUST write to the tree to do their job)
- Code-Conductor parallel Doc-Keeper documentation batches (same)

The classification names a real gap honestly: editor-required parallel dispatches under `workspace_mode: shared` interact with Step 0 dirty-fingerprint verification in ways the v1 handshake does not cleanly cover. The v2 `workspace_mode: worktree` schema (reserved) is the structural fix. Until v2, document the gap and link the follow-up issue #606.

### B' — Honest SKILL.md § Parallel-batch dispatch prose (documentation-only)

Revise `skills/subagent-env-handshake/SKILL.md` § Parallel-batch dispatch:

1. Replace the load-bearing claim "no tree mutation can occur between members of one parallel tool-use block" with the honest premise: "The **parent's** tool-call sequence cannot interleave with the parallel block. However, dispatched **subagents** share the working tree under `workspace_mode: shared`, and a subagent that mutates the tree during analysis can cause sibling subagents to observe divergent dirty fingerprints. The single-capture-per-batch policy depends on subagent working-tree discipline (see § Subagent working-tree discipline below) enforced at dispatch time via the prompt-prepended directive declared in the calling site."
2. Add an explicit failure-mode subsection: "If a subagent in a parallel batch mutates the tree during analysis, sibling subagents will observe divergent dirty fingerprints relative to the captured handshake and will halt with ND-2. The contract-recognized recovery path is the partial-pass-recovery clause in `commands/plan.md` and `commands/orchestra-review.md`."
3. Add a forward-compatibility note: under `workspace_mode: worktree` (v2, reserved), each subagent gets an isolated copy and the discipline dependency disappears.
4. Add a diagnostic note: ND-2 cascades in parallel batches do not provide per-pass attribution from the finding alone (each ND-2 finding shows the same parent-captured fingerprint vs three different observed fingerprints). Root-cause attribution requires correlating against subagent dispatch ordering.
5. Add a brace-anchor: wrap the load-bearing claim in `<!-- parallel-batch-honest-premise begin -->` / `<!-- /parallel-batch-honest-premise -->` so a Pester contract test can enforce the section content remains honest across future edits (mirrors the existing `<!-- capture-ordering-anchor -->` pattern).

### Adjacent — Partial-pass-recovery updates

Update `commands/plan.md` partial-pass-recovery clause and `commands/orchestra-review.md` partial-pass-recovery clause to:

1. Explicitly enumerate ND-2 environment-divergence as a retry trigger (currently enumerates only body-load failure + malformed output, leaving ambiguity about whether a well-formed ND-2 finding qualifies).
2. Add a one-sentence S4 framing: "ND-2 halts arising from sibling-subagent tree mutation under `workspace_mode: shared` are a documented recovery path declared in `skills/subagent-env-handshake/SKILL.md` § Subagent working-tree discipline, not a contract violation."

### Helpers — no changes required

`skills/subagent-env-handshake/scripts/*.ps1` parent-side helpers (`Get-FreshHandshake`, `New-SubagentDispatchPrompt`) do not change. The discipline is subagent-side behavioral; no parent-side enforcement path is feasible under `workspace_mode: shared`. Document this explicitly in the SKILL.md so future maintainers do not attempt a parent-side post-batch validation that cannot work.

## Acceptance Criteria

- **AC1** — `skills/subagent-env-handshake/SKILL.md` § Parallel-batch dispatch states the honest premise (subagent discipline at dispatch time is load-bearing, not parent-side ordering alone); names the failure mode; documents partial-pass-recovery as the recovery path; enumerates the parallel-batch dispatch sites with in-scope / out-of-scope classification; carries the `<!-- parallel-batch-honest-premise -->` anchor.
- **AC2** — `skills/subagent-env-handshake/SKILL.md` carries a new `## Subagent working-tree discipline (under workspace_mode: shared)` section declaring the read-only-during-analysis rule, scratch-space pattern, `scope: claude-only` boundary, and `workspace_mode: shared` conditional scope.
- **AC3** — `commands/plan.md`, `commands/orchestra-review.md`, and the design-challenge dispatch site (`skills/design-exploration/SKILL.md` or the calling site in `agents/Solution-Designer.agent.md`) prepend a directive to each parallel-batch `Agent` dispatch prompt referencing § Subagent working-tree discipline.
- **AC4** — `commands/plan.md` partial-pass-recovery clause enumerates ND-2 environment-divergence as a retry trigger AND carries the one-sentence S4 framing.
- **AC5** — `commands/orchestra-review.md` partial-pass-recovery clause carries the same enumeration AND framing. (Drop the original "if it inherits from a shared description" fallback — the two clauses are duplicate-authored today, no inheritance exists.)
- **AC6** — Add a Pester contract test (in `.github/scripts/Tests/subagent-env-handshake.Tests.ps1` or a sibling file) that asserts: (a) `skills/subagent-env-handshake/SKILL.md` carries the § Subagent working-tree discipline section heading; (b) the three dispatch sites contain a string referencing the discipline section; (c) the `<!-- parallel-batch-honest-premise -->` anchor wraps the load-bearing claim; (d) `commands/plan.md` and `commands/orchestra-review.md` partial-pass-recovery clauses contain `ND-2`/`environment-divergence` keywords.
- **AC7** — Existing Pester contract tests (handshake schema-parity, ND-2 finding template byte-identity, the inline prose template schema-parity test) still pass; any byte-identity fixture impacted by SKILL.md edits is updated in lockstep.
- **AC8** — Open a follow-up issue tracking the editor-parallel dispatch gap (Code-Smith ↔ Test-Writer, Doc-Keeper parallel batches) for resolution under `workspace_mode: worktree` v2; linked to issue #606 in the SKILL.md out-of-scope subsection.
- **AC9** — Cross-check `Documents/Design/hub-artifact-paths-audit.md` at plan phase. If the audit classifies the touched SKILL.md / commands files in a way that requires update, bundle the audit edit in the same PR; if no update is required, document that decision in the plan.
- **AC10** — Update the issue body's `### Related` section in this issue to cite `#485` (cost-completeness tempfile exception — adjacent because subagents now write scratch outside the repo root) and `#383` (original handshake skill design).

## Testing Scope

**Test types**: unit (Pester contract-parity), automated keyword-presence, manual integration.

**Named manual scenarios** (CE Gate `documentation` + `behavioral` surfaces):

- **M1 (behavioral, intent S1)** — Run `/plan` against a non-trivial GitHub issue on a near-clean tree post-change; observe 3-of-3 prosecution passes return ledgers without ND-2 halt. Compare to the live-evidence baseline in the engineering analysis below (2-of-3 halts on `/plan 557`).
- **M2 (documentation, intent S2/S3)** — Read the updated `skills/subagent-env-handshake/SKILL.md` § Parallel-batch dispatch + § Subagent working-tree discipline. Verify the load-bearing premise matches observable behavior. Verify cross-references from the partial-pass-recovery clauses resolve. Verify the diagnostic note explains the ND-2 attribution limitation.
- **M3 (Pester, AC6)** — Run the new Pester contract test; expect green. Then temporarily remove the § Subagent working-tree discipline section heading and re-run; expect red. (Validates the anchor protection.)
- **M4 (manual, AC4/AC5 framing, S4)** — Read the updated partial-pass-recovery clauses. Verify the S4 framing language is present and a planner would not interpret an ND-2 retry as a defect.

**Unit tests added**: Pester contract test per AC6 (one or two new `It` blocks in the handshake test file). The M3 manual scenario from the prior draft (force a one-shot write inside a Code-Critic dispatch) was removed during design challenge because reproducing it required user-side surgery in the dispatch prose; the Pester assertion in AC6 plus the live empirical evidence from the design-challenge dispatch (3-of-3 clean returns under the directive) provides equivalent coverage with lower friction.

**Out-of-scope tests**: no integration test exercises the editor-parallel gap (issue #606 carve-out). No browser/canvas/CLI/API tests apply.

## Rejected Alternatives

- **C — Pre-batch commit/stash** (parent stashes uncommitted work before the batch). **Why rejected**: live evidence shows the dominant cause was SUBAGENT-side mutations during analysis, not parent-side dirty state. Stashing the parent's tree does not prevent subagents from mutating it during analysis, so the same ND-2 pattern recurs. Adds user-surprise risk (stash + pop semantics on uncommitted work) for marginal benefit.
- **C added on top of A + B (belt-and-braces)**: **Why rejected**: redundant with A'.1 + A'.2 (which already prevent the dominant cause) and pays the user-surprise + rollback-complexity cost without addressing a residual failure mode that the revised A' + B' leaves open. Re-evaluate only if dispatch-time directives prove insufficient in practice.
- **D — Fingerprint tolerance window**: **Why rejected**: relaxes a precise signal into a fuzzy one. Real environment divergences with similar character (e.g., genuine branch drift, partially staged edits) would be masked. Contradicts the design intent of honest signal across every dispatch site, not just parallel batches.
- **E — Worktree mode for parallel batches**: **Why rejected**: explicitly out of scope per Experience-Owner framing (v2 schema work). A' + B' is a forward-compatible stepping stone — when E is undertaken, the discipline becomes a no-op for parallel batches and the SKILL.md prose can be extended to describe both modes. The editor-parallel gap (#606) is the natural place E is needed first.
- **B alone (doc-only)**: **Why rejected**: satisfies the maintainer-trust intent (S3) but not the planner functional intent (S1) — every parallel-batch run continues paying the ~20K-token retry cost. A'.1 + A'.2 are cheap enough to bundle, and the live evidence from the design-challenge prosecution shows the dispatch-time directive eliminates the dominant ND-2 cause.
- **A in agent bodies (original recommendation)**: **Why rejected**: cross-tool boundary violation. The shared `agents/Code-Critic.agent.md` and `agents/Code-Review-Response.agent.md` bodies are loaded by Copilot as well as Claude. Landing Claude-only methodology there contaminates Copilot's view with rationale that doesn't apply (Copilot doesn't perform Step 0 verification). Authoring the discipline in the already-`scope: claude-only` SKILL.md respects the boundary and keeps one source of truth. (Cluster A finding from the 3-pass adversarial design challenge.)
- **Code-Review-Response symmetric body subsection**: **Why rejected**: the Code-Review-Response judge is sequential today, not parallel-batch-dispatched. With the discipline relocated to the SKILL.md (per the bullet above), Code-Review-Response is automatically out-of-scope without a body-level carve-out. If a future issue parallelizes the judge, that issue can extend the SKILL.md scope at that time.

## Why A' + B' is the right recommendation

- **Closes both intent gaps under workspace_mode: shared**: S1 (no spurious halts on clean trees) is served by A'.2's dispatch-prompt directive — already empirically validated in this design-challenge dispatch (3-of-3 clean returns); S3 (maintainer can trust the contract) is served by B' making the rationale match reality and by AC6 protecting the contract from drift; S4 (planner experiences halt-then-recover without alarm) is served by the AC4/AC5 framing language.
- **Respects the cross-tool boundary**: Claude-only methodology lives in a `scope: claude-only` skill, not in cross-tool bodies that Copilot also loads.
- **Honest about what's still broken**: AC8 (issue #606) acknowledges the editor-parallel gap (Code-Smith ↔ Test-Writer, Doc-Keeper batches) instead of pretending it's solved. The honest contract names the limit; v2 worktree mode is the structural fix.
- **Forward-compatible**: explicit `workspace_mode: shared` scoping means v2 worktree-mode work only needs to define the worktree-mode behavior, not amend a load-bearing claim.
- **Protected against drift**: AC6's Pester contract test + the `<!-- parallel-batch-honest-premise -->` anchor prevent the SKILL.md from drifting back to optimistic phrasing.
- **Validated live**: the 3-pass adversarial design challenge for this very issue was dispatched with the proposed dispatch-time directive in each prompt. All three passes returned without ND-2 halts and self-reported tree-mutation discipline compliance. Direct empirical evidence the lever works.

---

## Engineering Analysis (preserved from original)

### Problem

`skills/subagent-env-handshake/SKILL.md` § Parallel-batch dispatch states:

> When a parent emits multiple `Agent` calls in one parallel tool-use block... per-dispatch recapture is satisfied by a **single live recapture immediately before the parallel block**, with one handshake block constructed per dispatch from those captured values... This is consistent with the per-dispatch policy because **no tree mutation can occur between members of one parallel tool-use block** — the dispatches fire as a single batch with no interleaved `Bash` or `Edit` calls.

The bolded claim is true at the **parent** level — the parent's own tool-call sequence cannot interleave with the parallel block. But in `shared` workspace mode (Claude Code's default), the dispatched **subagents** share the working tree with the parent. When a subagent performs its analysis, its `Bash`/`Edit`/etc. tool calls observe and can mutate the shared tree. Sibling subagents in the same parallel batch then observe each other's mutations when they run their Step 0 `git status --porcelain` verification — producing divergent dirty fingerprints relative to the parent's captured handshake.

### Live evidence

During `/plan 557` in conversation `<this session>` on 2026-05-20:

1. Parent captured handshake state with `dirty=1603d460cdc4` (an untracked `.tmp-557-plan-draft.md` was the only working-tree delta).
2. Parent dispatched 3 Code-Critic prosecution passes in a single parallel tool-use block.
3. Three observed outcomes:
   - **Pass 2** (P2): observed `1603d460cdc4` → handshake matched → 12-finding ledger returned.
   - **Pass 1** (P1): observed `150428c5a92f` → ND-2 environment-divergence → halted.
   - **Pass 3** (P3): observed `a88015f17e09` → ND-2 environment-divergence → halted.

Three different dirty fingerprints observed for the same parent-side captured handshake. The parent did not interleave any tool calls between the parallel-block members. The divergence is consistent with: at least two subagents writing a transient working-tree artifact (e.g., a Bash redirect of analysis output) within their analysis path, and a third subagent observing that artifact during its Step 0 verification.

After deleting the parent's untracked temp file and retrying the failed passes on a cleaner tree, both retried passes succeeded.

### Confirmation from /design 587 challenge run (2026-05-23)

During the 3-pass adversarial design challenge for this very issue (`/design 587`), the parent dispatched 3 Code-Critic passes in parallel — each prompt prepended with the proposed working-tree mutation discipline directive. All three passes returned cleanly with full prosecution ledgers; none halted ND-2; all three self-reported tree-mutation discipline compliance. The dispatch-time directive (Option A'.2) is empirically validated.

### Why this is a contract gap

The skill's "no tree mutation can occur between members of one parallel tool-use block" claim is the load-bearing premise for the parallel-batch policy. If that premise is provably wrong (and the live evidence shows it can be), then the policy's correctness argument needs to either:

1. Be revised to acknowledge subagent-side mutations as a real failure mode, OR
2. Constrain subagent behavior to prohibit working-tree mutations during analysis.

The revised design does both: subagent behavior is constrained via dispatch-time directives referencing the SKILL.md discipline (paths AC2 + AC3), and the contract is rewritten to honestly describe both the discipline dependency and the residual failure mode (AC1 + B').

### Customer impact

- **Planner running `/plan` on a non-trivial issue**: the 3-pass prosecution batch may produce partial-pass-recovery output (2-of-3 ledger after retry) or, on bad luck, both halts → both retries → cleaner result. Each halt + retry consumes a full subagent dispatch. The cost is observable but non-blocking thanks to the partial-pass-recovery clause in `commands/plan.md`.
- **`/orchestra:review` running prosecution × 3**: same shape; same cost.
- **Maintainer reading the SKILL.md contract**: a contract whose stated rationale is provably wrong erodes trust in the rest of the contract.

### Out of scope

- Removing the parallel-batch optimization itself — sequential prosecution dispatches are slow and the optimization is genuinely valuable.
- Removing `workspace_mode: shared` — that's Claude Code's default per the subagents docs; v1 of the handshake explicitly reserves `workspace_mode: worktree` for v2.
- Fixing the editor-parallel dispatch gap — Code-Conductor's `Execution Mode: parallel` lane (Code-Smith ↔ Test-Writer) and parallel Doc-Keeper batches both involve editor subagents whose role requires tree mutation, and the v1 handshake's dirty-fingerprint check is structurally incompatible with that. Tracked as follow-up issue #606; resolution belongs in v2 `workspace_mode: worktree`.

### Possible directions (design phase — superseded by the recommendation above)

The following five options were considered during design exploration. The maintainer approved A + B (scoped); the 3-pass adversarial design challenge then revised it to A' + B' as detailed in the Technical Design section.

- **Option A — Tighten subagent prose**: add to `agents/Code-Critic.agent.md` (and any other dispatchable subagent prose) a "do not write to the working tree during analysis" constraint. Subagents that need scratch space write outside the repo root.
- **Option B — Add tolerance to the contract**: rewrite the parallel-batch section of `subagent-env-handshake/SKILL.md` to acknowledge subagent-side tree mutations as a real failure mode, soften the "no tree mutation" claim, and document the partial-pass-recovery clause.
- **Option C — Pre-batch commit/stash**: before the parallel batch, the parent commits or stashes any working-tree deltas.
- **Option D — Fingerprint tolerance window**: relax ND-2 mismatch policy so the dirty-fingerprint field accepts a small window of divergence.
- **Option E — Worktree mode for parallel batches**: dispatch parallel subagents under `workspace_mode: worktree`.

### Severity

Medium. Recoverable via partial-pass-recovery + retry; each halt costs ~20K tokens. Pattern is reproducible and likely fires on most non-trivial `/plan` / `/orchestra:review` runs. The contract-vs-reality gap is the more concerning aspect than the per-run cost.

### Related

- [#383](https://github.com/Grimblaz/agent-orchestra/issues/383) — original handshake skill design
- [#485](https://github.com/Grimblaz/agent-orchestra/issues/485) — cost-completeness tempfile exception (adjacent: subagents now write scratch space outside the repo root after this issue lands)
- [skills/subagent-env-handshake/SKILL.md § Parallel-batch dispatch](skills/subagent-env-handshake/SKILL.md) — the section whose rationale needs revision
- [commands/plan.md § Partial-pass recovery](commands/plan.md) — the recovery clause that absorbs the cost today
- AC8 follow-up issue #606: editor-parallel dispatch gap under `workspace_mode: shared`; resolution in v2 worktree mode.
