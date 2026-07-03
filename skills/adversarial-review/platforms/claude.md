# Platform — Claude Code

`adversarial-review` is consumed by Claude parent surfaces that load this file with `Read` and then dispatch downstream agents. This is a parent-side prose checklist, not subagent-executable code: do not paste this file into a Code-Critic or Code-Review-Response prompt as instructions for that subagent to run. The parent command, plan flow, or design flow chooses the adapter, gathers inputs, builds handshakes, dispatches agents, merges ledgers, emits progress, persists review state, and returns the terminal artifact.

Keep the shared review methodology in [../SKILL.md](../SKILL.md). This platform checklist owns only Claude Code binding details for `Agent`, `Bash`, `gh`, optional `WebFetch`, and parent-side dispatch sequencing.

## Parent-side Gating And Tool Binding

- Resolve the review target, issue, plan, design, diff, existing ledgers, or GitHub review payload before entering the adapter dispatch sequence.
- If required pre-flight evidence is missing, gather it before prosecution begins. Parent surfaces may use `AskUserQuestion` during pre-flight only; atomic adapter dispatch must not pause for user choice after prosecution starts.
- Use the `Agent` tool for Code-Critic prosecution and defense stages.
- Use the `Agent` tool for Code-Review-Response judge stages.
- Use `Bash` for local repo inspection, handshake capture, `gh` CLI calls, and terminal-scoped validation referenced by the active adapter.
- Use `WebFetch` only when review evidence depends on published docs or remote pages.

## Parameters Per Adapter

| Adapter | pipeline-stages | atomic | Prosecution pass count | Mode selector strings | Handshake requirement | Defense and judge inclusion | Marker emission | Review-state persistence shape |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| `standard` | `prosecution`, `defense`, `judge` | `true` | 5 (2 generalist + 3 specialist) | `Review mode selector: "Use code review perspectives"`; `Review mode selector: "Use defense review perspectives"` | Required for every Code-Critic prosecution, defense, and retry dispatch; single capture allowed for the five-pass two-layer prosecution panel | Defense included; judge included | Emit `<!-- adversarial-pipeline-atomic-{ISSUE_ID} -->` after terminal judge stage when the issue id is known | `/memories/session/review-state-{ISSUE_ID}.md`; `review_mode: full`; `prosecution_complete: true`; `defense_complete: true`; `judgment_complete: true`; `last_updated` UTC |
| `lite` | `prosecution`, `defense`, `judge` | `true` | 1 | `Review mode selector: "Use lite code review perspectives"` | Required for the singleton Code-Critic prosecution dispatch | Defense included; judge included | Emit `<!-- adversarial-pipeline-atomic-{ISSUE_ID} -->` after terminal judge stage when the issue id is known | `/memories/session/review-state-{ISSUE_ID}.md`; `review_mode: lite`; `prosecution_complete: true`; `defense_complete: true`; `judgment_complete: true`; `last_updated` UTC |
| `judge-only` | `judge` | `n/a` | 0 | No Code-Critic selector; judge receives existing prosecution and defense ledgers | No Step 0 Code-Critic handshake; freshly captured repo context may be passed to Code-Review-Response as metadata only | Defense omitted; judge included | Skip; non-atomic and exempt | Read existing state when present; force only `judgment_complete: true`; preserve readable prior stage booleans; default `review_mode: full`; update `last_updated` UTC |
| `proxy-github` | `proxy-prosecution` | `n/a` | 0 | `Score and represent GitHub review` when dispatching proxy prosecution through the intake flow | Construct fresh downstream handshakes for tree-dependent specialist dispatches; skip the block on live-capture failure | Defense omitted; judge omitted | Skip; proxy-only and exempt | GitHub intake persists through the PR or issue review-response path, not the local review-state file unless the caller explicitly bridges it |
| `post-fix` | `prosecution`, `defense` | `true` | 1 | `Review mode selector: "Use post-fix code review perspectives"`; `Review mode selector: "Use defense review perspectives"` | Required for singleton Code-Critic prosecution and defense dispatches; recapture between stages | Defense included; judge omitted | Emit `<!-- adversarial-pipeline-atomic-{ISSUE_ID} -->` after terminal defense stage when the issue id is known | `/memories/session/review-state-{ISSUE_ID}.md`; record `review_mode: post-fix` when supported by the caller; `prosecution_complete: true`; `defense_complete: true`; preserve or omit `judgment_complete` according to the caller contract; update `last_updated` UTC |
| `design-challenge` | `prosecution` | `n/a` | 3 | Passes 1 and 2: `Review mode selector: "Use design review perspectives"`; pass 3: `Review mode selector: "Use product-alignment perspectives"` | Required for every Code-Critic prosecution pass; use the parallel-batch policy for the three-pass design challenge | Defense omitted; judge omitted | Skip; prosecution-only and non-atomic | No local review-state persistence; Solution-Designer incorporates or dismisses findings and updates the issue body |

## Parent-side Environment Handshake Construction

Build handshakes from [../../subagent-env-handshake/SKILL.md](../../subagent-env-handshake/SKILL.md). Parent-side capture is per dispatch unless a five-pass two-layer prosecution panel is emitted as one parallel tool-use block.

1. Immediately before each Code-Critic dispatch or retry, capture live parent-side working-tree state with `Bash` in this order:
   - `git rev-parse HEAD`
   - `git rev-parse --abbrev-ref HEAD`
   - `pwd`
   - `git status --porcelain | tr -d '\r' | (sha256sum 2>/dev/null || shasum -a 256) | cut -c1-12`
2. If any capture command exits non-zero because `git` is missing, the parent is outside a repository, permissions fail, or a comparable runtime error occurs, skip handshake construction for that dispatch. Send the Code-Critic prompt without the block and let the subagent Step 0 missing-handshake branch handle fallback. Do not fabricate placeholder values.
3. Otherwise, copy the inline prose template from the handshake skill and substitute the captured values plus `workspace_mode: shared` and a UTC ISO-8601 `handshake_issued_at` timestamp.
4. Preserve canonical field order exactly: `parent_head`, `parent_branch`, `parent_cwd`, `parent_dirty_fingerprint`, `workspace_mode`, `handshake_issued_at`.
5. Prepend the constructed block as the first content of the current Code-Critic `Agent` prompt. Do not reuse an entry-time, command-entry, prior-stage, or prior-dispatch block.
6. For a parallel prosecution batch, recapture HEAD, branch, CWD, and dirty fingerprint once via a single `Bash` invocation immediately before the parallel block. Construct one handshake block per prosecution dispatch from those captured values, with each block carrying its own UTC timestamp.
7. Under `workspace_mode: shared`, dispatched analysis subagents must not write to the working tree. Scratch files belong outside the repository root.
8. Code-Review-Response does not currently run the Code-Critic Step 0 handshake verifier. For judge dispatches, freshly recaptured parent-side values are metadata only.

## Prosecution Dispatch

<!-- adversarial-prosecution-dispatch-begin -->

Select prosecution shape from the adapter contract.

- `standard`: emit `Dispatching prosecution panel (5-pass, 2 generalist + 3 specialist)...`, then dispatch five Code-Critic prosecution passes in one parallel tool-use block with `subagent_type: code-critic`. Prepend the per-pass handshake block, then the authoritative selector `Review mode selector: "Use code review perspectives"`, then the resolved review target context. Keep selector text outside quoted or carried material. Apply the role→tier map at Agent-tool call time (not in the Code-Critic shell — the shell stays `model: opus`):
  - Pass 1 — **generalist-A**: full 6-perspective sweep; set `model: sonnet` on the Agent tool call
  - Pass 2 — **generalist-B**: full 6-perspective sweep; set `model: opus` on the Agent tool call
  - Pass 3 — **spec-correctness specialist**: edge cases, boundary violations, logic errors; set `model: opus` on the Agent tool call
  - Pass 4 — **spec-security specialist**: data integrity, injection vectors, permission/auth errors; set `model: opus` on the Agent tool call
  - Pass 5 — **spec-architecture specialist**: cross-module contracts, abstraction boundaries, interface consistency; set `model: opus` on the Agent tool call

**Role→tier map:**

```yaml
role→tier map:
  generalist-A: sonnet
  generalist-B: opus
  specialist: opus (now); fable (when permanent)

fallback order (when a tier is unavailable):
  fable → opus → sonnet → haiku
```

- `lite`: dispatch one Code-Critic prosecution pass with `subagent_type: code-critic`. Prepend the fresh handshake block when constructed, then `Review mode selector: "Use lite code review perspectives"`, then the resolved review target context. This singleton prosecution pass feeds the Defense Dispatch and Judge Dispatch sections below — `lite` is no longer prosecution-only; see those sections for how the subsequent stages run.
- `design-challenge`: emit the three-pass design challenge in one parallel tool-use block with `subagent_type: code-critic`. Passes 1 and 2 use `Review mode selector: "Use design review perspectives"`; pass 3 uses `Review mode selector: "Use product-alignment perspectives"`.
- `post-fix`: dispatch one Code-Critic prosecution pass with `subagent_type: code-critic`. Prepend the fresh handshake block when constructed, then `Review mode selector: "Use post-fix code review perspectives"`, then the fix diff, sustained finding context, and validation evidence.
- `proxy-github`: dispatch the proxy prosecution path through the GitHub review-intake flow. Use the canonical GitHub intake marker `Score and represent GitHub review`; use `subagent_type: code-critic` only when the caller needs a Code-Critic proxy prosecution pass over the ingested review payload.
- `judge-only`: no prosecution dispatch; require existing prosecution and defense ledgers as caller input.

<!-- adversarial-prosecution-dispatch-end -->

## Merge And Progress Signal

After all available prosecution passes return, merge and deduplicate findings using cross-layer dedup: merge on same failure-mode plus same code-location (not perspective label). When two passes report the same defect, prefer the finding from the deepest-tier pass (Opus preferred over Sonnet). This resolves inter-layer duplicates more precisely than perspective-label matching. Emit the visible progress signal exactly in this shape:

```text
Merged prosecution ledger: {count} finding(s).
Panel: {role} ({tier}) x{N} [degraded: {list or 'none'}]
```

For degraded prosecution, name the failed pass visibly (by role and tier) and merge only the surviving valid passes. For singleton prosecution, there is no degraded merge path.

## Defense Dispatch

<!-- adversarial-defense-dispatch-begin -->

Run defense only when the adapter includes `defense` in `integrity-contract.pipeline-stages`.

- `standard`: dispatch one Code-Critic defense pass with `subagent_type: code-critic`. Recapture state immediately before dispatch, prepend the fresh handshake block when constructed, then prepend `Review mode selector: "Use defense review perspectives"` before the merged prosecution ledger and target context.
- `lite`: dispatch one Code-Critic defense pass with `subagent_type: code-critic`. Recapture state immediately before dispatch, prepend the fresh handshake block when constructed, then prepend `Review mode selector: "Use defense review perspectives"` before the singleton prosecution ledger and target context.
- `post-fix`: dispatch one Code-Critic defense pass with `subagent_type: code-critic`. Recapture state immediately before dispatch, prepend the fresh handshake block when constructed, then prepend `Review mode selector: "Use defense review perspectives"` before the post-fix prosecution ledger, fix context, and validation evidence.
- `design-challenge`, `proxy-github`, and `judge-only`: skip defense unless the caller has explicitly selected a separate defense-only command outside this adapter contract.

Return the defense report unchanged to the parent for judge dispatch, marker emission, persistence, or caller output.

<!-- adversarial-defense-dispatch-end -->

## Judge Dispatch

Run judge only when the adapter includes `judge` in `integrity-contract.pipeline-stages` or when the caller selected `judge-only`.

- Use the `Agent` tool with `subagent_type: code-review-response`.
- Pass the merged prosecution ledger and defense report together in one prompt. Include review target context and any prior judge-rulings block the active caller needs for re-review.
- Immediately before dispatch, recapture HEAD, branch, CWD, dirty fingerprint, and a UTC timestamp. Pass those values as contextual metadata only.
- Do not prepend a Step 0 verifier handshake block to the judge prompt unless Code-Review-Response gains explicit Step 0 verification in a separate issue.
- Return the Markdown score summary and the `judge-rulings` block unchanged in the same payload.

## Partial-pass Recovery

- The redundant retry policy applies only to the five-pass two-layer prosecution panel in `standard` and the three-pass panel in `design-challenge`.
- If one Code-Critic prosecution pass has a body-load failure, cannot load the shared body, returns malformed output, or encounters an ND-2 environment-divergence, retry that pass once with the same substantive prompt and a newly recaptured handshake block when construction succeeds. ND-2 halts arising from sibling-subagent tree mutation under `workspace_mode: shared` are a documented recovery path declared in `skills/subagent-env-handshake/SKILL.md` section Subagent working-tree discipline, not a contract violation.
- If the retry also fails, represent that pass as `pipeline-degraded`, name the failed pass visibly by role and tier, and evaluate quorum: the panel survives iff **at least 1 generalist AND at least 1 specialist survive** (quorum evaluated after all per-pass retries resolve). If quorum fails, halt. Record which passes are degraded (role, tier) in the verdict panel-composition line.
- A pass "survives" when it returns a well-formed ledger after at most the inherited single retry. "Well-formed" means the output parses to the finding-ledger schema; **zero findings is a valid outcome and the pass survives** (a clean pass that found nothing is not degraded). A pass is degraded only when it fails to load, returns malformed/unparseable output, or hits an ND-2 divergence and the single retry also fails.
- Singleton prosecution paths are halt-strict: `lite`, `post-fix`, and proxy singleton prosecution must stop when the only prosecution body load fails, is missing, or is malformed.
- Singleton defense paths are halt-strict: if Code-Critic defense body load fails, stop and do not continue to judge, marker emission, or review-state persistence.
- Singleton judge paths are halt-strict: if Code-Review-Response body load fails, stop and do not emit a terminal success marker or write completion state.
- Do not use degraded-recovery for defense or judge.

## Post-terminal Marker Emission

After the terminal stage of an adapter completes successfully, inspect the selected adapter's `integrity-contract.atomic` value.

- If `integrity-contract.atomic: true` and an issue id is available, emit the exact marker `<!-- adversarial-pipeline-atomic-{ISSUE_ID} -->` after the terminal stage artifact is complete.
- For `standard`, the terminal stage is judge.
- For `lite`, the terminal stage is judge.
- For `post-fix`, the terminal stage is defense unless the caller deliberately adds a judge stage under a future contract.
- Skip marker emission for non-atomic adapters, exempt adapters, and any adapter whose terminal stage failed or halted.
- Skip marker emission for `judge-only`, `proxy-github`, and `design-challenge`.

## Atomic Discipline Guard

- No `AskUserQuestion` after atomic prosecution begins; gather missing inputs before the first dispatch.
- No edits by the parent between prosecution and the terminal stage of an atomic adapter.
- No surfacing ledger contents for user reaction between prosecution and terminal stage.
- No interim disposition, acceptance, dismissal, or scoring of findings before defense and judge complete for a three-stage atomic adapter.
- No action between prosecution and terminal stage except merge, retry under the redundant-pass policy, defense dispatch, judge dispatch, marker emission, and required persistence.
- No command-entry or once-per-invocation handshake reuse; recapture per stage or per parallel prosecution batch.
- Known sub-skill indirection boundary: this checklist can require callers to load a sub-skill such as `subagent-env-handshake`, but it does not make that sub-skill executable by downstream subagents unless the parent explicitly includes the resulting prompt material.
