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

## Surface & CE Gate Readiness

| Surface | Applies? | CE Gate readiness | Notes |
| --- | --- | --- | --- |
| `documentation` (SKILL.md prose, agent-body prose) | ✅ Yes | Ready — verifiable by reading the updated SKILL.md text and any updated `agents/*.agent.md` guardrail prose against the customer-facing rationale claim. | Primary surface. The maintainer-trust intent (S3) is exercised here. |
| `behavioral` (parallel-batch dispatch in `/plan`, `/orchestra:review`) | ✅ Yes | Baseline-comparable — issue body already captures live evidence of 2-of-3 halts on a near-clean tree; a post-change run on a clean tree provides the comparison. | Exercised by S1 and S4. |
| `cli` | ✅ Yes | Ready — Claude slash-command surface (`/plan`, `/orchestra:review`) qualify as the CLI surface for the M1 functional scenario | Exercised by M1 in s8. |
| `browser` | ❌ No | n/a | No browser surface. |
| `canvas` | ❌ No | n/a | No canvas surface. |
| `api` | ❌ No | n/a | No HTTP/API surface. |

**Hub/consumer classification**: stays in hub. `skills/subagent-env-handshake/` is a Claude Code-only skill (`scope: claude-only`) governing the Claude Agent-tool dispatch model. No consumer-repo artifact applies; no language-specific content is involved.

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

### Why this is a contract gap

The skill's "no tree mutation can occur between members of one parallel tool-use block" claim is the load-bearing premise for the parallel-batch policy. If that premise is provably wrong (and the live evidence shows it can be), then the policy's correctness argument needs to either:

1. Be revised to acknowledge subagent-side mutations as a real failure mode, OR
2. Constrain subagent behavior to prohibit working-tree mutations during analysis.

Without one of those, every parallel Code-Critic batch (the default `/plan` adversarial pipeline and `/orchestra:review`'s prosecution × 3 batch) carries a non-zero ND-2 halt rate that the policy doesn't accommodate.

### Customer impact

- **Planner running `/plan` on a non-trivial issue**: the 3-pass prosecution batch may produce partial-pass-recovery output (2-of-3 ledger after retry) or, on bad luck, both halts → both retries → cleaner result. Each halt + retry consumes a full subagent dispatch. The cost is observable but non-blocking thanks to the partial-pass-recovery clause in `commands/plan.md`.
- **`/orchestra:review` running prosecution × 3**: same shape; same cost.
- **Maintainer reading the SKILL.md contract**: a contract whose stated rationale is provably wrong erodes trust in the rest of the contract.

### Out of scope

- Removing the parallel-batch optimization itself — sequential prosecution dispatches are slow and the optimization is genuinely valuable.
- Removing `workspace_mode: shared` — that's Claude Code's default per the subagents docs; v1 of the handshake explicitly reserves `workspace_mode: worktree` for v2.

### Possible directions (design phase, not pre-committed here)

- **Option A — Tighten subagent prose**: add to `agents/Code-Critic.agent.md` (and any other dispatchable subagent prose) a "do not write to the working tree during analysis" constraint. Subagents that need scratch space write outside the repo root. Lowest-impact change; relies on subagent discipline.
- **Option B — Add tolerance to the contract**: rewrite the parallel-batch section of `subagent-env-handshake/SKILL.md` to acknowledge subagent-side tree mutations as a real failure mode, soften the "no tree mutation" claim, and document the partial-pass-recovery clause as the load-bearing recovery path rather than the optimization's correctness argument. Documentation-only.
- **Option C — Pre-batch commit/stash**: before the parallel batch, the parent commits or stashes any working-tree deltas so the captured handshake is against a fully-clean tree; instructs subagents that any tree state they observe is post-stash. Behavioral change; affects all parallel-batch sites.
- **Option D — Fingerprint tolerance window**: relax ND-2 mismatch policy so the dirty-fingerprint field accepts a small window of divergence (e.g., "fingerprint differs but only in untracked-file additions" passes as match). Contract relaxation; could mask real divergences.
- **Option E — Worktree mode for parallel batches**: dispatch parallel subagents under `workspace_mode: worktree` (currently reserved in v1) so each subagent gets an isolated copy. Highest-impact change; advances the v2 schema work.

A combination of A + B is plausible (and cheap): tighten subagent prose to avoid the mutation pattern, and update the contract to acknowledge that subagent discipline is the load-bearing premise (not parent-side ordering alone).

### Severity

Medium. Recoverable via partial-pass-recovery + retry; each halt costs ~20K tokens. Pattern is reproducible and likely fires on most non-trivial `/plan` / `/orchestra:review` runs. The contract-vs-reality gap is the more concerning aspect than the per-run cost.

### Related

- [#383](https://github.com/Grimblaz/agent-orchestra/issues/383) — original handshake skill design
- [skills/subagent-env-handshake/SKILL.md § Parallel-batch dispatch](skills/subagent-env-handshake/SKILL.md) — the section whose rationale needs revision
- [commands/plan.md § Partial-pass recovery](commands/plan.md) — the recovery clause that absorbs the cost today
