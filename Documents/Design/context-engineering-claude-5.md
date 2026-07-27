# Context Engineering for Claude 5 — Assessment and Recommended Changes

**Status**: Assessment (no changes applied yet)
**Sources**: Anthropic, "The new rules of context engineering for Claude 5 generation models" (claude.com blog, July 2026, Thariq Shihipar); "Prompting Claude Fable 5" (platform.claude.com docs); "Introducing Claude Fable 5 and Claude Mythos 5" (platform.claude.com docs).
**Date**: 2026-07-27

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

Small, additive, high value for `/goal-run` (Arm I) and `/spine-run`:

1. **Progress-claim grounding**: "Before reporting progress, audit each claim against a tool result from this session. Only report work you can point to evidence for; if something is not yet verified, say so explicitly." This belongs in the Goal-Run body and the Senior Engineer dispatch preamble — it directly hardens halt reports and `halt_return` YAML against fabricated status, the failure mode the unattended harness can least afford.
2. **Autonomy reminder**: "You are operating autonomously. … Before ending your turn, check your last paragraph. If it is a plan, a question, or a promise about work you have not done, do that work now with tool calls." Prevents the documented rare early-stop (text-only "I'll now run X" without the tool call) — which in an unattended goal-run would strand the inflight marker.
3. **Anti-overbuilding at high effort**: "Don't add features, refactor, or introduce abstractions beyond what the task requires…" in the implementation-discipline adapter, since slice executors now run on models that over-deliver at high effort.

### R3 — Re-tune effort declarations downward for routine roles

Every shell currently declares `high` (one `xhigh`). The guidance is explicit that lower effort on Claude 5 often beats `xhigh` on prior models, and that high effort on routine work produces over-deliberation. Proposed split:

- Keep `high`/`xhigh` where depth is the product: adversarial review roles (`code-critic`, `code-review-response`), deep synthesis (`solution-designer`, `issue-planner`, `research-agent`, `specification`).
- Drop to `medium` for routine/mechanical roles: predicate-adapter evaluation, `process-review`, `refactor-specialist` on mechanical sweeps, and orchestrator turns whose job is dispatch bookkeeping rather than reasoning.

This is a cost-and-latency win with no quality claim being relaxed, so it does not require ledger evidence — but the calibration-pipeline skill is the natural place to measure before/after.

### R4 — Handle Fable 5 refusals at the two pinned dispatch sites

`code-review-response` pins `model: fable`, and prosecution generalist-B dispatches on `fable`. Fable 5's classifiers target offensive cybersecurity; adversarial prosecution of security-sensitive diffs (exploit-adjacent code, credential handling, attack-surface analysis) can occasionally trip them even when benign. The fallback order is documented in `agent-body-architecture.md`, but nothing states *when* it fires. Add one rule to `skills/adversarial-review/platforms/claude.md`: a `fable` dispatch that returns a refusal (or dies without output) is re-dispatched once on `opus` with the same prompt, and the substitution is recorded in the pass metadata. Cheap insurance for the review pipeline's most capable seat.

### R5 — Exploit parallel and long-lived subagents in orchestration

Code-Conductor and Spine-Runner currently dispatch one specialist per slice, sequentially, and block until return. Two upgrades the guidance now endorses:

- **Parallel dispatch of independent slices.** The chunked-delivery doctrine already makes independence explicit (chunk seams, `depends-on` edges in the frame spine). Slices with no unmet `depends-on` can dispatch concurrently.
- **Long-lived executors across slices.** Re-using one Senior Engineer agent for consecutive slices in the same chunk (continue-by-message rather than fresh dispatch) preserves its warm context, saves cache reads, and matches the "long-lived subagents that keep context across subtasks" recommendation. The `subagent-env-handshake` skill is the natural home for the continuation contract.

Sequence R5 *after* R1 — parallelism multiplies whatever per-dispatch context weight exists today.

### R6 — Add intent context to dispatch prompts ("the reason, not only the request")

`dispatch-prompt-economy` currently optimizes for pointing at canonical sources and minimizing inline prose. Keep that, but add one required line to every specialist dispatch: *why this slice exists* — the customer-visible outcome it serves, one sentence, sourced from the Experience-Owner framing already on the issue. The guidance is that Claude 5 performs measurably better with intent context, and the upstream pipeline already produces it; today it just isn't threaded into dispatches.

### R7 — Add a lessons-memory layer

The Session Memory Contract persists *decisions and handoffs*; nothing persists *lessons* (corrections, confirmed approaches, "this pattern failed because…") across runs. Add a lightweight store — one lesson per Markdown file, one-line summary on top, per the guidance's recipe — surfaced by the `session-startup` skill, with the guidance's hygiene rules (don't duplicate what the repo records; update rather than duplicate; delete wrong notes). Bootstrap it once by having Claude review past session transcripts/issues for recurring themes.

### R8 — What *not* to change

- **Engagement gates and adversarial review stay.** The blog's "remove guardrails" targets model-behavior coaching, not methodology checkpoints. The gates encode the quality-first doctrine and relax only via phase-containment-ledger evidence — that mechanism is unchanged. What Claude 5 *does* change is the expectation: with higher first-shot correctness, later stages' irreducible-catch rates should start trending down. Watch the ledger; when a stage demonstrably catches nothing new on Claude 5, retire it through the existing process.
- **No new reasoning-visibility features.** Any future ask for "show the agent's reasoning in the report" must be satisfied from work products (findings, evidence, rulings), never by instructing the model to reproduce its thinking — that is the `reasoning_extraction` refusal trap.
- **Contracts keep their precision.** Marker schemas, precedence orders, and enum literals are load-bearing; the trim in R1 must not blur them.

## Suggested sequencing

| Order | Item | Effort | Risk |
| --- | --- | --- | --- |
| 1 | R2 harness instructions | Small | Low — additive |
| 2 | R4 refusal fallback rule | Small | Low — additive |
| 3 | R3 effort re-tune | Small | Low — measurable via calibration pipeline |
| 4 | R6 intent line in dispatches | Small | Low |
| 5 | R1 prescription-debt audit | Large | Medium — governed by ledger + D10 ceiling |
| 6 | R7 lessons memory | Medium | Low |
| 7 | R5 parallel/long-lived executors | Large | Medium — sequence after R1 |

Each of R1–R7 should become its own issue through the normal upstream pipeline; R1 is the umbrella-scale item and the one with the largest expected payoff, since a lighter context surface improves every dispatch downstream.
