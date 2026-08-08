# Context Engineering for Claude 5 — Assessment and Recommended Changes

**Status**: Assessment record — this document applies no changes; execution sequencing is owned by the portfolio (see #933)
**Sources**: Anthropic, "The new rules of context engineering for Claude 5 generation models" (claude.com blog, July 2026, Thariq Shihipar); "Prompting Claude Fable 5" (platform.claude.com docs); "Introducing Claude Fable 5 and Claude Mythos 5" (platform.claude.com docs).
**Date**: 2026-07-27 (assessment); sequencing settled 2026-08-08; recommendation text corrected 2026-08-08 after adversarial review of PR #1020 (marked **[corrected 2026-08-08]** inline — the assessment's July judgments are otherwise unaltered)
**Sequencing (settled 2026-08-08, recorded on #933)**: #970 → #761 (incl. the #944 siblings) → #936's chunks → #923 cost-truth → then open #933 for R1/R3/R5, so the trim program reads instruments that are trustworthy by the time it runs. R2 and R4 are carved out ahead of that order as small additive children (no instrument dependency): they harden the very goal-lane runs whose soak window generates the evidence the rest of the sequence reads. R3 additionally waits behind #923 because an effort re-tune would confound its before/after cost comparison.

## What Anthropic's guidance says

The blog's headline finding: Anthropic removed over 80% of Claude Code's own system prompt for Claude 5 generation models (Opus 5, Fable 5) with **no measurable loss** on coding evaluations. Many constraints were guardrails for older model behavior that Claude 5 no longer needs — and instead of helping, they created friction: conflicting instructions, over-specified rules that were wrong in edge cases, and context that crowded out the model's own judgment. Anthropic also shipped a `claude doctor` command that helps simplify context automatically.

The companion docs page ("Prompting Claude Fable 5") turns that into concrete rules. The ones relevant to this repository:

1. **Refactor existing prompts and skills.** "Skills developed for prior models are often too prescriptive for Claude Fable 5 and can degrade output quality. Review and consider removing older instructions if default performance is better."
2. **Never instruct the model to echo or transcribe its internal reasoning.** Such instructions trigger the `reasoning_extraction` refusal classifier on Fable 5, causing elevated fallbacks.
3. **Effort is the primary quality/latency/cost lever.** `high` is the default; lower effort on Fable 5 still often exceeds `xhigh` performance on prior models. Higher effort on routine work causes over-deliberation and unrequested tidying.
4. **Longer turns by default; check on runs asynchronously** rather than blocking.
5. **Parallel and long-lived subagents.** Claude 5 dispatches parallel subagents dependably; prefer asynchronous orchestrator↔subagent communication and long-lived subagents that keep context across subtasks (cache reads, no bottleneck on the slowest agent).
6. **Ground progress claims in tool results.** An "audit each claim against a tool result from this session" instruction nearly eliminated fabricated status reports in Anthropic's testing.
7. **Autonomous pipelines need an explicit autonomy reminder** (no mid-task questions; check your last paragraph for unfinished promises before ending a turn) to prevent rare early stopping.
8. **Avoid surfacing remaining-token countdowns** to the model in long sessions.
9. **Construct a memory system** — a place to record one lesson per file across runs.
10. **Give the reason, not only the request** — intent context outperforms bare task statements, especially for agents drawing on multiple workstreams.
11. **Fresh-context verifier subagents outperform self-critique** for long-run verification.
12. **Plan for refusals where Fable 5 is used.** Safety classifiers target offensive cybersecurity, biology, and reasoning extraction; benign work can occasionally trigger them. Configure fallback to another Claude model.

## What this repository already gets right

The audit found the repo is in better shape than the blog's average reader:

- **No reasoning-echo instructions anywhere.** A sweep of `skills/`, `agents/`, `commands/`, and `CLAUDE.md` for "show your reasoning / transcribe your thinking / chain of thought"-class instructions found zero hits. The biggest Fable 5 refusal risk is absent.
- **Model routing is already Claude 5-aware.** `Documents/Design/agent-body-architecture.md` records the 2026-07-25 Opus 5 alias resolution (#905); the standard prosecution panel already routes generalist-B to `fable` (DD4, #785); a fallback order (`fable → opus → sonnet → haiku`) is documented; `code-review-response` runs `fable + xhigh`. Both-or-neither `model:`/`effort:` discipline is Pester-enforced.
- **Fresh-context adversarial verification is the house style.** Prosecution → defense → judge with independent subagent dispatch is exactly the "separate, fresh-context verifier subagents" pattern the guidance recommends over self-critique.
- **Durable, harness-external memory exists.** The Session Memory Contract (GitHub-issue markers) survives session loss — a stronger version of the "write state outside the context window" principle.
- **Evidence-gated simplification machinery already exists.** The phase-containment ledger (relax a stage only when its irreducible-catch rate trends to ~0) and the D10 guidance-complexity soft ceiling (`skills/guidance-measurement/`, `agents_over_ceiling`) are precisely the instruments needed to act on rule 1 without guessing.
- **The unattended harness halts instead of asking.** `/goal-run`'s typed halt reports match the "don't block on questions mid-pipeline" posture, and serve the role of a send-to-user channel for unattended runs.

## Recommended changes, ranked

### R1 — Run a prescription-debt audit on the largest context surfaces (highest value)

The measured surface: `CLAUDE.md` ≈ 3.2k words, agent bodies ≈ 46.5k words, skills ≈ 96.6k words. Top density of imperative guardrails (`MUST`/`NEVER`/`ALWAYS`/`DO NOT` per file): `plan-authoring` (70), `Goal-Run.agent.md` (62), `Code-Conductor.agent.md` (46), `review-judgment` (38), `safe-operations` (32). This is the exact profile the blog names: rules accreted to steer older models, now competing with the model's judgment.

The audit should sort every instruction into two piles:

- **Contracts** — marker formats, precedence orders, schemas, enum literals, gate definitions, non-overridability clauses. These encode *system invariants*, not model coaching. **Keep them exact.** (Example: the `Resolve-GoalRunInvocationAction` precedence documentation is a contract.)
- **Behavioral coaching** — step-by-step narration of how to think, enumerated failure-mode lists, "do not forget to…" reinforcement, restatements of the same rule in multiple places. These are Claude-4-era guardrails and the prime removal candidates.

Route removals through the existing governance rather than wholesale deletion: use `guidance-measurement` to pick over-ceiling targets, trim coaching, and let the phase-containment ledger confirm nothing regressed. This honors the repo's own "remove later checks only with evidence" doctrine — the blog supplies the *prior* (Claude 5 needs less coaching), the ledger supplies the *evidence*.

Also run `claude doctor` against a consumer install of the plugin; it is purpose-built to flag conflicting and redundant instructions in assembled context.

### R2 — Add the three Fable-specific harness instructions to autonomous paths

Small, additive, high value for `/goal-run` (Arm I — the unattended vendor-goal-loop harness; see [HOW-IT-WORKS.md § Goal-run](../../HOW-IT-WORKS.md#3-goal-run-the-unattended-pipeline)) and `/spine-run`:

1. **Progress-claim grounding**: "Before reporting progress, audit each claim against a tool result from this session. Only report work you can point to evidence for; if something is not yet verified, say so explicitly." This belongs in the Goal-Run body and the Senior Engineer dispatch preamble — it directly hardens halt reports and `halt_return` YAML against fabricated status, the failure mode the unattended harness can least afford.
2. **Autonomy reminder**: "You are operating autonomously. … Before ending your turn, check your last paragraph. If it is a plan, a question, or a promise about work you have not done, do that work now with tool calls." Prevents the documented rare early-stop (text-only "I'll now run X" without the tool call) — which in an unattended goal-run would strand the inflight marker.
3. **Anti-overbuilding at high effort**: "Don't add features, refactor, or introduce abstractions beyond what the task requires…" in the implementation-discipline adapter, since slice executors now run on models that over-deliver at high effort.

### R3 — Re-tune effort declarations downward for routine roles

Every shell currently declares `high` (one `xhigh`). The guidance is explicit that lower effort on Claude 5 often beats `xhigh` on prior models, and that high effort on routine work produces over-deliberation. Proposed split:

- Keep `high`/`xhigh` where depth is the product: adversarial review roles (`code-critic`, `code-review-response`), deep synthesis (`solution-designer`, `issue-planner`, `research-agent`, `specification`).
- Drop to `medium` for routine/mechanical roles: predicate-adapter evaluation, `process-review`, `refactor-specialist` on mechanical sweeps, and orchestrator turns whose job is dispatch bookkeeping rather than reasoning.

**[corrected 2026-08-08]** The drop-target list above names a granularity the mechanism cannot express, and R3's first design question is what to do about that. `effort:` is a **per-shell frontmatter declaration** (`Documents/Design/agent-body-architecture.md` § Per-agent model + reasoning routing), so of the four named targets: *orchestrator turns* is not addressable (`agents/code-conductor.md` declares one value for the whole shell, gate turns included), *`refactor-specialist` on mechanical sweeps* is not addressable (no per-sweep lever), and *predicate-adapter evaluation* has no shell at all (`adapter-type: predicate` resolves to `executor: inline`). Only `process-review` is expressible — and its own routing-table row justifies its tier as "workflow meta-analysis requires extended reasoning," which contradicts classifying it routine. Re-derive the target list from shells whose whole role is routine before proposing any value change.

**[corrected 2026-08-08]** The original text claimed this "does not require ledger evidence." That claim is withdrawn: an effort re-tune is large enough to confound #923's before/after cost comparison (which is why the settled sequencing puts R3 behind it), and a change that can confound another issue's instrument is not one with nothing to measure. Ledger *gating* is still not imported here — the phase-containment doctrine governs retiring review stages by irreducible-catch rate, and an effort declaration is not a review stage — but the calibration pipeline is the place to measure before/after, and R3 owes that measurement rather than an exemption from it.

### R4 — Handle Fable 5 refusals at the two pinned dispatch sites

`code-review-response` pins `model: fable`, and prosecution generalist-B dispatches on `fable`. Fable 5's classifiers target offensive cybersecurity; adversarial prosecution of security-sensitive diffs (exploit-adjacent code, credential handling, attack-surface analysis) can occasionally trip them even when benign. The fallback order is documented in `agent-body-architecture.md`, but nothing states *when* it fires. Add one rule to `skills/adversarial-review/platforms/claude.md`: a `fable` dispatch that returns a refusal (or dies without output) is re-dispatched once on `opus` with the same prompt, and the substitution is recorded in the pass metadata. Cheap insurance for the review pipeline's most capable seat.

**[corrected 2026-08-08]** Three corrections; R4 is neither as simple nor as additive as written above, and its scope is now carried by its child issue rather than this paragraph.

1. **The premise was already false when this was written.** `skills/adversarial-review/platforms/claude.md:152` has carried a generalist-B refusal reroute since 2026-07-03 (#790) — 24 days before this assessment. One of the two named seats is already covered.
2. **Refusal and death-without-output are different failure classes and must not share a retry.** A refusal (`stop_reason: refusal`) is a clean no-op and reroutes safely. A dispatch that dies without returning may have completed side effects first: the judge's own step 9 persists the `<!-- review-judge-produced-{PR} -->` sentinel (idempotent) and *then* posts the `judge-rulings` comment, which carries **no** idempotency guard — so a same-prompt retry can leave two rulings comments with different verdicts, and the credit harvester (`skills/calibration-pipeline/references/review-credit-emission.md`) selects with `Select-Object -Last 1`, i.e. silently. The plan surface faced this and its owner decision (811-D1, `skills/plan-authoring/SKILL.md`) *rejected* latest-wins in favor of failing loud; the two schemas are not interchangeable, so that is an analogy rather than a breach — but it is the same trap.
3. **Extending this to the judge reverses a standing decision.** The same file states at `:151-152` that degraded-recovery is not used for defense or judge, and that the reroute "does not apply to judge-class dispatches." A judge-covering retry rule is therefore a reversal requiring its own argument plus a write-idempotency protocol — not the "Low — additive" change the sequencing table below rates it.

### R5 — Exploit parallel and long-lived subagents in orchestration

Code-Conductor and Spine-Runner currently dispatch one specialist per slice, sequentially, and block until return. Two upgrades the guidance now endorses:

- **Parallel dispatch of independent slices.** The chunked-delivery doctrine already makes independence explicit (chunk seams, `depends-on` edges in the frame spine). Slices with no unmet `depends-on` can dispatch concurrently.
- **Long-lived executors across slices.** Re-using one Senior Engineer agent for consecutive slices in the same chunk (continue-by-message rather than fresh dispatch) preserves its warm context, saves cache reads, and matches the "long-lived subagents that keep context across subtasks" recommendation. The `subagent-env-handshake` skill is the natural home for the continuation contract.

Sequence R5 *after* R1 — parallelism multiplies whatever per-dispatch context weight exists today.

**[corrected 2026-08-08]** Three premise corrections; each becomes a design question R5 must answer rather than inherit as settled:

- **`depends-on` does not establish write-independence.** Per `skills/plan-authoring/SKILL.md` it is an explicit depth-1, deliberately non-transitive field whose purpose is bounding specialist prompts — context provisioning, not a write-set declaration. Two slices can both carry no unmet `depends-on` and still edit the same file, so concurrent dispatch needs its own independence check (write-set declaration, conflict detection, or workspace isolation).
- **Editor-parallel batches have no documented v1 recovery.** They sit outside the analysis-only read-only discipline in `skills/subagent-env-handshake/SKILL.md` (so this is not a prohibition — `skills/parallel-execution/SKILL.md` already ships parallel Code-Smith ↔ Test-Writer dispatch), but that skill also records that under `workspace_mode: shared` such batches may produce ND-2 cascades with no documented recovery clause in v1, tracked as #606. R5 either waits on that or supplies the missing clause.
- **Continuation-by-message bypasses the handshake.** The per-dispatch environment recapture obligation is keyed to `Agent` dispatches, so a continued executor never re-runs Step 0 and carries the prior slice's `parent_head` and dirty fingerprint after the parent has committed. The continuation contract must define live recapture (or an explicit, argued exception) — naming `subagent-env-handshake` as its home does not by itself close the gap.

### R6 — Add intent context to dispatch prompts ("the reason, not only the request")

`dispatch-prompt-economy` currently optimizes for pointing at canonical sources and minimizing inline prose. Keep that, but add one required line to every specialist dispatch: *why this slice exists* — the customer-visible outcome it serves, one sentence, sourced from the Experience-Owner framing already on the issue. The guidance is that Claude 5 performs measurably better with intent context, and the upstream pipeline already produces it; today it just isn't threaded into dispatches.

### R7 — Add a lessons-memory layer

The Session Memory Contract persists *decisions and handoffs*; nothing persists *lessons* (corrections, confirmed approaches, "this pattern failed because…") across runs. Add a lightweight store — one lesson per Markdown file, one-line summary on top, per the guidance's recipe — surfaced by the `session-startup` skill, with the guidance's hygiene rules (don't duplicate what the repo records; update rather than duplicate; delete wrong notes). Bootstrap it once by having Claude review past session transcripts/issues for recurring themes.

### R8 — What *not* to change

- **Engagement gates and adversarial review stay.** The blog's "remove guardrails" targets model-behavior coaching, not methodology checkpoints. The gates encode the quality-first doctrine and relax only via phase-containment-ledger evidence — that mechanism is unchanged. What Claude 5 *does* change is the expectation: with higher first-shot correctness, later stages' irreducible-catch rates should start trending down. Watch the ledger; when a stage demonstrably catches nothing new on Claude 5, retire it through the existing process.
- **No new reasoning-visibility features.** Any future ask for "show the agent's reasoning in the report" must be satisfied from work products (findings, evidence, rulings), never by instructing the model to reproduce its thinking — that is the `reasoning_extraction` refusal trap.
- **Contracts keep their precision.** Marker schemas, precedence orders, and enum literals are load-bearing; the trim in R1 must not blur them.

## Suggested sequencing

> **This table is the July 2026 assessment's recommended order and does not override the settled portfolio sequence in the header.** Where the two differ, the header (line 6) governs. The rows are retained because they carry the only ordering statement for **R6 and R7**, which the settlement does not address. Row-level status is marked below as of 2026-08-08.

| Order | Item | Effort | Risk | Status (2026-08-08) |
| --- | --- | --- | --- | --- |
| 1 | R2 harness instructions | Small | Low — additive | **Carved out early** — filed as #1021 (child of #848); no instrument dependency |
| 2 | R4 refusal fallback rule | Small | ~~Low — additive~~ **Not additive** — reverses a standing carve-out (see R4 corrections) | **Carved out early** — filed as #1022; scope corrected |
| 3 | R3 effort re-tune | Small | ~~Low — measurable via calibration pipeline~~ **Measurable only after #923** — run before it, the calibration measurement this cell offered as the mitigation is itself confounded | **Superseded by the header: R3 waits behind #923.** Not a do-now item; see also the R3 drop-target corrections. |
| 4 | R6 intent line in dispatches | Small | Low | Unsettled — this row is the current ordering statement |
| 5 | R1 prescription-debt audit | Large | Medium — governed by ledger + D10 ceiling | **Superseded by the header**: opens with #933 after #970 → #761 → #936 → #923 |
| 6 | R7 lessons memory | Medium | Low | Unsettled — this row is the current ordering statement; note the memory-store redesign (#1017–#1019) now overlaps its territory and must be reconciled at open |
| 7 | R5 parallel/long-lived executors | Large | Medium — sequence after R1 | **Superseded by the header**: opens with #933; see the R5 premise corrections first |

Each of R1–R7 should become its own issue through the normal upstream pipeline; R1 is the umbrella-scale item and the one with the largest expected payoff, since a lighter context surface improves every dispatch downstream.
