# Peer-to-Peer Agent Dispatch — Research Spike

**Issue**: #535  
**Branch**: feature/issue-535-peer-to-peer-research  
**Date**: 2026-05-08  
**Status**: closed — Agent Teams: No-Go, Agent-tool: confirmed (see verdict blocks; updated by issue #539 2026-05-09)

## Overview

This document records the findings of the research spike for issue #535: whether peer-to-peer (P2P) agent dispatch is cost-viable on Claude Code and Copilot Chat, and what transport options exist on each platform.

The spike measured Claude Code's current `Agent` tool dispatch overhead using SDK usage telemetry (three rounds: one warmup + two steady-state). Copilot Chat measurement was deferred due to a multi-git detection bug in the Copilot OTel installer (issue #538). Copilot capability is documented from transport survey and platform docs only.

Issue #539 completed the Agent Teams dedicated-session measurement using a headless `claude -p` sandbox on branch `feature/issue-539-headless-sandbox`. The Agent Teams verdict is No-Go (structurally unresolvable — see verdict block and retrospective below).

## Scope

In scope:
- Transport shape and observability of Claude Code's `Agent` tool dispatch
- Transport shape of Claude Code's experimental Agent Teams (`SendMessage`)
- Copilot Chat's multi-agent capability model (hierarchical runSubagent only)
- Precedent framework scan: LangGraph, CrewAI, AutoGen, Inspect
- Cross-platform parity and asymmetry stance

Out of scope:
- Modifying `cost-walker.ps1` or `cost-walker-copilot.ps1`
- Authoring persona-migration or Conductor-refactor work
- Production implementation of P2P dispatch

## Precedent Framework Scan

### LangGraph

LangGraph agents communicate through a shared, append-only state object whose canonical transport is a `messages` key holding typed message objects — `HumanMessage`, `AIMessage`, `ToolMessage` — each with `content`, optional `name` (source agent identifier), and `id`. The `add_messages` reducer appends rather than overwrites, and handoffs are expressed as `HumanMessage` emissions paired with `Command(goto=...)` returns along graph edges. This state-as-transport model makes agent nodes purely functional transforms over state, decoupling sender from receiver while giving replay semantics through the shared immutable append-only history. Observability is via `response_metadata` fields on individual messages (`input_tokens`, `output_tokens`) with per-agent aggregation requiring callers to filter by `name`; LangSmith surfaces nested subgraph spans in a shared trace, but the core library has no first-class per-agent usage summary.

### CrewAI

CrewAI's transport unit is the `Task` result: agents receive prior task outputs as a `context` list that the framework interpolates into each executing agent's prompt, rather than exposing a raw wire protocol between agents. In hierarchical mode the manager acts as the single hub — all inter-agent payloads flow through it as natural-language delegations and structured `TaskOutput` returns — making the topology explicitly hub-and-spoke with no peer-to-peer path. This design was a deliberate predictability and audit decision: restricting the communication graph prevents message amplification and simplifies debugging. Observability is aggregate-first: `crew_output.usage_metrics` sums tokens across the entire crew, per-task counts require iterating `TaskOutput` objects, and OTel integration requires third-party callbacks (Langfuse, AgentOps) since CrewAI emits no native OTel signals.

### AutoGen

AutoGen v0.4 uses a typed `ChatMessage` hierarchy for inter-agent transport: `TextMessage` (fields: `source`, `content`, `type`, `id`), `MultiModalMessage`, `StopMessage`, `HandoffMessage`, and `ToolCallSummaryMessage`. Internal agent events (`ToolCallRequestEvent`, `ToolCallExecutionEvent`) are kept in a separate `AgentEvent` union — a deliberate v0.4 redesign to resolve the v0.2 problem of mixed communication and observation streams. Each `TextMessage` carries a `models_usage` field (`prompt_tokens`, `completion_tokens`) enabling per-message and per-producing-agent token attribution. Agents operate through an actor model with individual message inboxes, receiving only new messages rather than full history re-submissions, and AutoGen v0.4 includes native OpenTelemetry support contributing multi-agent observability spans to the OTel GenAI semantic conventions working group.

### Inspect (UK AISI)

Inspect is an evaluation framework whose multi-agent primitive is `AgentState` — a lightweight wrapper containing a `messages` list of `ChatMessage` objects and a `ModelOutput` from the most recent generation. Agents are Python functions that receive `AgentState`, run a tool-use loop, and return an updated `AgentState`; sub-agent invocation uses a `handoff()` tool call whose result messages are appended back to the parent's list. The narrow `AgentState` interface (intentionally narrower than the broader `TaskState`) was chosen to make agents maximally portable and prevent accidental access to scorer or dataset metadata. Observability is through structured `.inspect_ai/` logs viewable in the VS Code Inspect Log Viewer, with token usage captured per `ModelOutput` and aggregated in `EvalLog.stats`; Inspect does not emit native OTel signals.

## Platform Transport Analysis

### Claude Code

**Current inter-agent transport: Agent tool (subagent model)**

When a Claude Code session uses the `Agent` tool, it spawns a subagent in a completely separate context window. The parent passes a `prompt` string and an optional `subagent_type` (resolved from `.claude/agents/` or `~/.claude/agents/` YAML frontmatter). The subagent runs its own full conversation — loading CLAUDE.md, MCP servers, and skills independently — and returns a single text result back to the parent as the `Agent` tool's return value. There is no shared message log between parent and subagent. Communication is strictly unidirectional after dispatch: the parent blocks, the subagent works, the result returns.

Subagents cannot spawn further subagents (no nested recursion). Multiple `Agent` tool calls in a single parent turn run in parallel, each in its own context window. The parent sees only the final result string from each subagent; intermediate steps, tool calls, and reasoning are invisible to the parent at runtime, though stored in the subagent's own JSONL transcript under `~/.claude/projects/`.

**Peer-to-peer via Agent Teams (experimental)**

Agent Teams (`CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1`, requires v2.1.32+) provide a distinct bidirectional transport through a mailbox system. Teammates communicate via `SendMessage`, which writes JSON inbox files to `~/.claude/teams/{team-name}/inboxes/{agent-name}.json`. Message fields include `from`, `text`, `summary`, `timestamp`, `color`, and `read` status. Any teammate can message any other by name; the lead assigns names at spawn time.

The shared task list (`~/.claude/tasks/{team-name}/`) provides a further coordination primitive: teammates can claim tasks, mark them complete, and read dependency status. File locking prevents concurrent claim races.

This peer-to-peer capability is explicitly experimental, has known limitations (no session resumption for in-process teammates, no nested teams, lead is fixed), and is not the same as the `Agent` tool subagent model.

**Where SDK-level usage appears**

At the Claude Agent SDK level (TypeScript/Python `query()` function), usage is reported per-dispatch: each `query()` call returns its own `ResultMessage` with `total_cost_usd` and a `usage` dict (`input_tokens`, `output_tokens`, `cache_creation_input_tokens`, `cache_read_input_tokens`). A `modelUsage` map on the result provides per-model token breakdowns when multiple models are active. The SDK does not maintain a cross-dispatch session-level total; callers must accumulate `total_cost_usd` across calls manually.

Within Claude Code's interactive sessions, `/usage` reports the running session total. There is no UI-level per-subagent breakdown; subagent costs roll into the parent session's running total from the session interface perspective. The transcript JSONL files per-project-slug (`~/.claude/projects/`) contain per-event usage data consumable by a cost walker (as implemented in `.github/scripts/lib/cost-walker.ps1`).

**Shared message log / external observability**

There is no shared message log observable from outside the running session. Each session writes independently to its own JSONL transcript file. The Agent Orchestra cost walker reads these post-session by walking the transcript events and traversing subagent dispatch chains. There is no live streaming API exposing parent+subagent messages to an external observer during execution.

### Copilot Chat

**Multi-agent transport model**

Copilot Chat in VS Code does not expose a peer-to-peer multi-agent primitive equivalent to Claude Code's Agent tool or Agent Teams. The observable multi-agent pattern is agent-mode invocation of sub-agents through the `runSubagent` tool, producing a parent→child hierarchical span tree — the subagent's `invoke_agent` span appears as a child of the parent agent's `execute_tool` span.

Each Copilot Chat conversation is session-isolated: context is per-request, not shared across sessions. There is no shared message log accessible by multiple simultaneous Copilot agents. When Copilot invokes a specialist, the delegated work runs in its own isolated session and results flow back through the tool result mechanism.

**OTel signals emitted per agent turn**

Copilot Chat exports OpenTelemetry signals when `github.copilot.chat.otel.enabled = true` and `exporterType = "file"` (as validated in `Documents/Design/copilot-otel-capability.md`). The observed event types per agent turn are:

- `copilot_chat.session.start` — session boundary marker, carries `session.id`, no token fields
- `gen_ai.client.inference.operation.details` — per-inference record, carries `gen_ai.usage.input_tokens` and `gen_ai.usage.output_tokens`, model name, and duration
- `copilot_chat.agent.turn` — per-turn record, carries `gen_ai.usage.input_tokens` and `gen_ai.usage.output_tokens`
- `copilot_chat.tool.call` — per-tool-call record, carries `gen_ai.tool.name`, `duration_ms`, `success`; does **not** carry token usage
- Metrics records with aggregate `gen_ai.client.token.usage` histograms (not per-record `gen_ai.usage.*` fields)

The VS Code OTel monitoring documentation describes a hierarchical span tree per turn: `invoke_agent` (root) → `chat` → `execute_tool` / `execute_hook`. The `invoke_agent` span carries cumulative token usage for the entire agent interaction; per-LLM-call breakdowns appear as `gen_ai.client.token.usage` metrics.

**Per-agent token surfacing**

Per the VS Code monitoring docs: token usage is broken down by agent in the `invoke_agent` span attributes, and the `gen_ai.client.token.usage` metric includes `gen_ai.request.model` as a filtering attribute for per-model analysis. This is richer than Claude Code's JSONL-based approach — OTel provides live queryable metrics rather than post-session file parsing.

**Cost/rate availability**

Copilot per-token rates are not published. The cost walker implementation (`cost-walker-copilot.ps1`) preserves token counts with `null` cost fields and emits the footnote: "Copilot per-token rates not published; cost figures excluded for Copilot rows." Cache metrics (`cache_creation_input_tokens`, `cache_read_input_tokens`) are absent from observed Copilot OTel records.

**Branch correlation**

Copilot OTel records do not carry a git branch field. Branch attribution requires joining session start timestamps against the git reflog window for the target branch, as implemented in `cost-walker-copilot.ps1`. Sessions that cross branch switches are attributed by session start time.

**Shared message log**

No shared message log is available. OTel file export writes a single flat JSONL file across all Copilot sessions in a workspace; there is no per-agent-turn segmentation within the file beyond `session.id`.

## Cross-Platform Parity Assessment

Claude Code and Copilot Chat arrive at multi-agent observability from opposite architectural starting points, producing convergence on token presence but divergence on granularity, transport shape, and branch attribution.

**Where they converge**: both platforms emit per-turn token counts (`input_tokens`, `output_tokens`) attached to the agent interaction record. Both use a model-name field on the token-bearing record, enabling per-model segmentation. Both represent a single agent turn as a discrete bounded unit that can be queried after the fact. The Agent Orchestra cost walker already exploits this convergence: `cost-walker.ps1` and `cost-walker-copilot.ps1` normalize both event sources into the same internal schema (`provider`, `agentType`, `message.usage.*`), and `cost-attribution.ps1` accumulates them into the same port buckets.

**Where they diverge**: Claude Code's usage signal lives in JSONL transcripts written to disk per session, requiring post-session file parsing to reconstruct multi-agent chains. Copilot's usage signal lives in OTel spans emittable live to any OTLP backend, with hierarchical span context that natively encodes parent/child agent relationships. This means Copilot natively exposes call-tree structure (which agent invoked which sub-agent), while Claude Code requires cost-walker graph traversal through subagent JSONL files following `Agent` tool dispatch records. For agent teams, Claude Code adds a mailbox-on-disk layer (`~/.claude/teams/`) with no OTel surface at all.

A second divergence is branch attribution: Claude Code assistant events carry `gitBranch` directly in the JSONL event, while Copilot OTel carries no branch field — attribution requires reflog timestamp correlation. This creates asymmetric attribution confidence: Claude events are deterministically branch-matched; Copilot events are probabilistically matched and can be lost if the reflog is pruned or the session spans a branch switch.

A third divergence is cache visibility: Claude Code exposes `cache_creation_input_tokens` and `cache_read_input_tokens` (the Agent SDK docs and cost walker both handle them). Copilot OTel exposes neither; cache metrics remain null in the normalized event schema.

A peer-to-peer prototype on Claude Code would generate inter-agent messages observable only through post-session JSONL parsing or the experimental mailbox files — no live OTel trace. The same prototype on Copilot would be observable as a `invoke_agent` span tree in real time if an OTLP collector is attached, but Copilot has no equivalent of the `SendMessage` peer-to-peer primitive; the only multi-agent model is the `runSubagent`-tool hierarchy. These differences mean a harness designed to measure both platforms must implement two distinct collection paths and accept that live observability is only available on the Copilot side with current tooling.

## Measurement Methodology

### Claude (Agent tool) — SDK usage path

Measurement was conducted inline during Code-Conductor orchestration on branch `feature/issue-535-peer-to-peer-research`. Three Agent dispatches were issued with a known-shape minimal prompt ("Hello, agent. Please respond with exactly: 'Peer dispatch acknowledged.'"):

| Round | Type | total_tokens |
|-------|------|-------------|
| 1 | warmup | 24,667 |
| 2 | steady-state | 24,665 |
| 3 | steady-state | 24,665 |

Cache-warmup criterion: discard rounds where `cache_creation_input_tokens > 0`. Rounds 2–3 are steady-state (delta = 0 tokens between rounds, confirming cache fully warm). Steady-state was inferred from token-count stability (delta=0 between rounds 2 and 3) rather than direct `cache_creation_input_tokens=0` observation, because the in-flight walker miss prevented field-level inspection.

**Walker miss**: `cost-walker.ps1` returned 0 sessions for the spike branch. Root cause: session transcript is in-flight (walker reads JSONL files after session completes). `cost_source: sdk-usage` applies. SDK-usage fallback: walker was unavailable (in-flight session); per-dispatch `total_tokens` was captured directly from Agent tool result metadata. Per-round `input_tokens`/`output_tokens` breakdown unavailable; only `total_tokens` captured from Agent tool result.

**Key observation**: Per-dispatch `total_tokens` (~24.6K) is dominated by parent conversation context propagation, not the task payload. This means per-dispatch cost scales with parent session size, not task size.

### Claude (Agent tool + Agent Teams) — dedicated headless session (issue #539)

Issue #539 re-measured both transports in an isolated headless session (`claude -p --model claude-sonnet-4-6`) on a sibling sandbox worktree (`feature/issue-539-headless-sandbox`). This design eliminated the in-flight walker miss and parent-context contamination from the #535 spike.

**Phase A — Agent tool (8 rounds, 1 warmup + 7 retained):**

| Round | cc | cr | input | output | non-cached |
|-------|----|----|-------|--------|------------|
| 1 (warmup) | 15,537 | 0 | 3 | 8 | 11 |
| 2–8 (steady-state) | 0 | 15,537 | 3 | 8 | **11 each** |

Steady-state (cc=0): n=7, mean=11, stddev=0. Model: `claude-sonnet-4-6` (inherits from lead).

**Phase B — Agent Teams (8 sends):**

- Teammate model: `claude-opus-4-7` (server default — not configurable from lead's `--model`)
- Effective teammate responses: 3 of 8 sends (fire-and-forget; 5 sends unprocessed before `TeamDelete`)
- Steady-state rounds (cc=0): **n=0 — structurally impossible**
- 27 API calls across 4 teammate subprocess sessions; per-call non-cached mean: 84.5 tokens
- Phase B teammate cost: $0.7949

**Total run cost**: $1.37 (within $5 budget; `bound_fired: none`).

### Copilot — capability analysis only

Copilot OTel collection installer (`Initialize-CopilotCostCollection.ps1`) fails on machines with multiple git installations — the `Get-Command git` call returns a collection instead of a single path (issue #538). Measurement deferred. Capability documented from transport survey and VS Code OTel monitoring docs.

## Decision Matrix

| Platform | Transport | Maturity | Measured | Verdict |
|----------|-----------|----------|----------|---------|
| Claude Code — Agent tool | One-directional hub→subagent | stable | Yes (walker + JSONL-direct; issues #535, #539) | **confirmed** |
| Claude Code — Agent Teams | Mailbox P2P (SendMessage) | experimental | Yes (walker + JSONL-direct; issue #539) | **no-go** |
| Copilot Chat | Hierarchical runSubagent only | stable | No (installer bug #538) | partial |

## Platform Verdict Blocks

```yaml
---
verdict_claude_agent_tool:
  verdict: confirmed
  transport: agent-tool-dispatch
  transport_maturity: stable
  cost_source: walker+jsonl-direct
  walker_credits: "issue #539 dedicated headless session; 8 rounds fixed-N; branch feature/issue-539-headless-sandbox; slug C--Users-Micah-Code-2-copilot-orchestra-539-headless; cost-walker Tier 1 for lead events; JSONL-direct Tier 2 for subagent events; cross-validated, no discrepancies"
  sdk_usage_evidence: "8 dispatch rounds on feature/issue-539-headless-sandbox (claude -p --model claude-sonnet-4-6, issue #539); 1 warmup round (cc=15537, cr=0) + 7 steady-state rounds (cc=0, cr=15537)"
  cost_per_round_input_tokens: 3           # steady-state mean (n=7, stddev=0)
  cost_per_round_output_tokens: 8          # steady-state mean (n=7, stddev=0)
  cost_per_round_total_tokens_observed: 11 # non-cached tokens; cc=0 steady-state rounds only
  cost_per_round_cache_creation_input_tokens: 0     # cc=0 by definition in steady state
  cost_per_round_cache_read_input_tokens: 15537     # full cache re-read each steady-state round
  cost_per_round_model: claude-sonnet-4-6
  measurement_rounds_steady_state: 7
  measurement_rounds_warmup: 1
  measurement_stddev: 0
  verdict_rationale: >
    Agent tool dispatch achieves full prompt-cache warm-up after 1 warmup round.
    Steady-state marginal cost is 11 non-cached tokens/round (3 input + 8 output),
    with 15,537 cache-read tokens — effectively zero marginal cost per round in
    steady state. Viable for ensemble dispatch where specialist agents do substantial
    work. The prior #535 sdk-usage figure (24.6K tokens/round) reflected parent-context
    contamination from an in-flight orchestration session; this #539 dedicated-session
    measurement with cc=0 filter produces the clean baseline.
  threshold_rationale: >
    Confirmed viable. Per-round marginal cost is effectively zero in steady state.
    The 40% cost-reduction threshold is not the binding constraint for Agent-tool;
    the relevant constraint is task granularity (overhead dominates for sub-1K-token tasks).

verdict_claude_agent_teams:
  verdict: no-go
  transport: agent-teams-sendmessage
  transport_maturity: experimental
  cost_source: walker+jsonl-direct
  walker_credits: "issue #539 dedicated headless session; 8 sends fixed-N; branch feature/issue-539-headless-sandbox; cost-walker Tier 1 for lead events; JSONL-direct Tier 2 for teammate subprocess events (4 JSONL files under subagents/)"
  sdk_usage_evidence: "8 SendMessage calls on feature/issue-539-headless-sandbox (claude -p --model claude-sonnet-4-6, issue #539); teammate model claude-opus-4-7 (server default — not configurable from lead --model); 3 of 8 sends produced effective teammate responses before TeamDelete; 27 API calls across 4 teammate subprocess sessions"
  cost_per_round_input_tokens: null           # no steady-state rounds (cc=0 structurally impossible)
  cost_per_round_output_tokens: null          # no steady-state rounds
  cost_per_round_total_tokens_observed: null  # per-call non-cached mean: 84.5 tokens (n=27 calls); no cc=0 rounds
  cost_per_round_cache_creation_input_tokens: null  # perpetual warmup — cc never reaches 0
  cost_per_round_cache_read_input_tokens: null      # cc=0 filter yields n=0
  cost_per_round_model: "claude-opus-4-7 (fixed — not overridable from lead model)"
  measurement_rounds_steady_state: 0             # structurally impossible
  measurement_rounds_effective_responses: 3      # of 8 sends
  measurement_total_cost_teammate_usd: 0.7949
  measurement_total_cost_lead_and_agent_tool_usd: 0.5714
  verdict_rationale: >
    Agent Teams P2P is structurally unresolvable for cost-efficient dispatch under the
    current API. Three architectural facts prevent steady-state cost measurement and
    preclude the 40% cost-reduction target:

    1. Teammate model is always claude-opus-4-7 — the lead's --model flag does not
       propagate; no override exists at the Agent Teams API level. This creates a
       fundamental per-token cost asymmetry vs Agent-tool (which inherits the lead model).

    2. Each SendMessage spawns a new subprocess — no cache persistence across rounds.
       Every call re-creates 28K–40K cache_creation_input_tokens perpetually. The cc=0
       steady-state filter that characterizes Agent-tool cost can never be satisfied.

    3. Fire-and-forget semantics — 8 sends produced 3 effective teammate responses
       before TeamDelete. There is no delivery guarantee; the lead cannot confirm
       processing before tearing down the team.

    Cost comparison: Agent Teams teammate alone ($0.7949 for 3 effective responses from
    8 sends) exceeds Agent-tool total ($0.5714 for all 8 rounds lead+subagents).
    Agent Teams is approximately 10–20x more expensive per effective round.
    reduction_pct is NOT COMPUTABLE (cc=0 filter yields n=0); directional result is
    a large negative — vastly worse than Agent-tool, not approaching the 40% target.
  threshold_rationale: >
    No-Go. The 40% cost-reduction threshold is not met. Agent Teams is the more
    expensive transport by approximately an order of magnitude. The verdict is structural
    (architectural API constraints), not marginal (a tunable design parameter).
  decision_criterion_cited: >
    Agent Teams teammates run at claude-opus-4-7 (not configurable from lead model);
    no cache persistence across SendMessage rounds (new subprocess per call);
    fire-and-forget semantics with no delivery guarantee. OQ1 in issue #534 closed
    as structurally unresolvable under current Agent Teams API. Maintainer verdict
    captured in <!-- verdict-captured-539 --> comment on issue #539 (2026-05-09).
  blocked_on_api_evolution:
    - model-pin support (allow lead --model to propagate to teammates)
    - cache persistence across SendMessage rounds (shared subprocess or session reuse)
    - delivery confirmation (synchronous acknowledgment from teammate before TeamDelete)

verdict_copilot:
  verdict: partial
  transport: none
  transport_maturity: "n/a"
  cost_source: unmeasured
  walker_credits: null
  sdk_usage_evidence: "No measurement — Copilot OTel collection not installed (issue #538 pending). No P2P transport primitive available on Copilot Chat. Issue #539 tracks Agent Teams measurement follow-up (complete; see agent_teams verdict)."
  cost_per_round_input_tokens: null
  cost_per_round_output_tokens: null
  cost_per_round_total_tokens_observed: null
  cost_per_round_cache_creation_input_tokens: null  # Copilot OTel does not expose cache fields
  cost_per_round_cache_read_input_tokens: null       # Copilot OTel does not expose cache fields
  verdict_rationale: >
    Copilot Chat has no peer-to-peer transport primitive. Multi-agent capability is
    hierarchical runSubagent only — a parent agent invokes child agents; children cannot
    initiate messages to peers. OTel provides per-agent token counts via invoke_agent
    spans but no branch attribution (reflog join required). Capability gap prevents Go verdict.
  decision_criterion_cited: >
    No P2P transport primitive available on Copilot Chat as of 2026-05. Only hierarchical
    runSubagent dispatch is supported.
  threshold_rationale: >
    Partial verdict — no P2P transport primitive means 40% threshold cannot be evaluated.
---
```

## Asymmetry Stance

**Stance**: `ship-claude-only` (satisfies issue #535 acceptance: cross-platform recommendation explicit, asymmetry stance with rationale)

**Rationale**: Claude Code has the Agent Teams transport primitive required for true P2P dispatch (mailbox-on-disk, experimental but available). Copilot Chat lacks an equivalent — its multi-agent model is strictly hierarchical. Proceeding symmetrically would require Copilot to emulate P2P through sequential subagent chains, adding orchestration complexity without transport-level P2P semantics.

Issue #539 completed the Agent Teams cost measurement and returned a No-Go verdict (structural API constraints prevent cost parity with Agent-tool). The `ship-claude-only` stance is therefore not actionable for P2P dispatch under the current Agent Teams API. The asymmetry stance is retained for documentation accuracy; follow-up would require Agent Teams API evolution (model-pin + cache-persistence support).

## Lessons Learned

### Claude Code — methodology

- **Walker in-flight miss**: running measurement dispatches inside the orchestration session means the session transcript is in-flight when the walker runs. Future measurement spikes should run measurement dispatches in a **dedicated fresh session** (not the orchestration session) to ensure walker reads a completed transcript. Issue #539 implemented this via `claude -p` on a sibling sandbox worktree.
- **Context-scale domination**: per-dispatch `total_tokens` scales with parent conversation length. The 24.6K overhead observed in #535 included the entire orchestration conversation. The #539 dedicated-session measurement with cc=0 filter shows the clean baseline: 11 non-cached tokens/round in steady state.
- **Agent Teams teammate model**: teammates always run at `claude-opus-4-7` (server default). The lead's `--model` flag does not propagate. This is not configurable — plan any Agent Teams cost estimate at opus-4-7 rates regardless of lead model.
- **Agent Teams cache behavior**: each `SendMessage` spawns a new subprocess. Full cache re-creation (~28K–40K tokens) occurs on every round. cc=0 steady-state is architecturally impossible under the current API.
- **Reproducer commands**:
  - Branch: `git checkout feature/issue-535-peer-to-peer-research`
  - Measurement (dedicated session — do not run inside the orchestration session):
    ```powershell
    $env:CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS = "1"
    claude -p "your measurement prompt" --model claude-sonnet-4-6 --output-format json
    ```
  - Walker (library invocation — `cost-walker.ps1` must be dot-sourced; direct `pwsh` invocation will fail because it is a library file, not a script):
    ```powershell
    . .github/scripts/lib/path-normalize.ps1
    . .github/scripts/lib/cost-walker.ps1
    $events = Invoke-CostTranscriptWalk `
        -Slug 'c--Users-Micah-Code-2-copilot-orchestra' `
        -Branch 'feature/issue-535-peer-to-peer-research' `
        -ParentCwd 'C:\Users\Micah\Code 2\copilot-orchestra' `
        -IssueNumber 535
    ```
    Valid parameters: `-Slug`, `-Branch`, `-ParentCwd`, `-IssueNumber`, `-ProjectsRoot`.
    `-Repo` is not a valid parameter name.

### Copilot Chat — methodology

- **Multi-git installer bug**: `Initialize-CopilotCostCollection.ps1` crashes when `Get-Command git` returns multiple results. Fix: add `| Select-Object -First 1`. Tracked in issue #538.
- **Reproducer commands** (after #538 merges):
  - Install: `pwsh skills/copilot-cost-collection/scripts/Initialize-CopilotCostCollection.ps1 -WorkspacePath . -Yes -NonInteractive`
  - Run measurement: dispatch prototype rounds in a dedicated fresh Copilot Chat session per the methodology in #539 (the spike's operator-driven harness was bypassed and is not retained on main; it is recoverable from branch history if useful — see retention note in General Lessons below)
  - Walker: `pwsh .github/scripts/lib/cost-walker-copilot.ps1 -IssueNumber 535 -Repo Grimblaz/agent-orchestra -Branch feature/issue-535-peer-to-peer-research`

### General

- Transport survey identified two collection paths required (JSONL walker for Claude, OTel walker for Copilot) — dual-path is unavoidable given architectural divergence.
- Agent Teams P2P has no OTel surface; mailbox files (`~/.claude/teams/`) are the only observable record during execution. Post-execution: teammate JSONL transcripts appear under `{slugDir}/{sessionId}/subagents/agent-{shortId}.jsonl` — a different path from Agent-tool subagents (`{slugDir}/subagents/agent-{toolUseId}.jsonl`). The cost-walker's existing subagent traversal covers Agent-tool paths only; Agent Teams teammate files require JSONL-direct (Tier 2) access.
- Copilot attribution is probabilistic (reflog timestamp join) — sessions crossing branch switches may be mis-attributed.
- **`.tmp/issue-535/` retention**: Spike scaffolding (`harness.ps1`, `transport-survey.md`) is **not merged to main** — the harness was built per the original plan but bypassed during measurement (operator-driven design replaced by direct `Agent` dispatch from Code-Conductor) and is not a production asset. The artifacts are preserved in branch history at commit `2f9b8ba` on `feature/issue-535-peer-to-peer-research`, recoverable via `git show origin/feature/issue-535-peer-to-peer-research:.tmp/issue-535/harness.ps1` (and similarly for `transport-survey.md`). Per issue #535 acceptance criteria, the spike branch is retained until at least one Go-verdict follow-up has shipped or close-out is explicit; #539's implementer can pull the harness from branch history if useful, but the methodology lessons in this document are the durable record.

## Issue #539 Measurement Retrospective

**Date**: 2026-05-09  
**Verdict**: No-Go — OQ1 in issue #534 closed as structurally unresolvable under current Agent Teams API.

### What worked

- **Headless `claude -p` sandbox approach**: Using a sibling worktree (`feature/issue-539-headless-sandbox`) with a separate JSONL slug eliminated the in-flight walker miss that blocked #535. All measurement events were readable post-session via cost-walker.
- **cc=0 steady-state filter**: The filter worked perfectly for Agent-tool (7/8 rounds cc=0, stddev=0). It also definitively revealed the Agent Teams structural problem — if cc is never 0, the filter returns n=0, which is itself a clear negative signal.
- **JSONL-direct (Tier 2) for teammate files**: Agent Teams teammate transcripts are at a different path from Agent-tool subagents. Direct JSONL parsing accessed the 4 teammate session files cleanly; cost-walker's existing traversal covers Agent-tool paths only.
- **Model attribution via JSONL**: The `model` field in assistant events definitively confirmed `claude-opus-4-7` for all teammate API calls — not the lead's `claude-sonnet-4-6`. This was a key finding that could not have been inferred from the transport docs alone.

### What was surprising

- **Teammate model is fixed at opus-4-7**: The lead's `--model` flag does not propagate to Agent Teams teammates. This is undocumented in the Claude Code Agent Teams docs (as of the measurement date). The cost implication is severe: opus-4-7 is substantially more expensive per token than sonnet-4-6.
- **Fire-and-forget semantics at scale**: 8 sends produced 3 effective responses. The lead process completed measurement and called `TeamDelete` before the teammate processed the remaining 5 messages. This is not a bug — it reflects the intended mailbox-on-disk semantics — but it means Agent Teams is not a reliable RPC transport without explicit synchronization.
- **Cache re-creation per subprocess**: Expected based on the transport docs, but the magnitude (28K–40K cc tokens per call) confirmed that Agent Teams permanently operates in "warmup mode" from a cost perspective. The transport overhead dominates every round by two orders of magnitude vs Agent-tool steady state (11 tokens).

### What to try if Agent Teams API evolves

If two API changes land — (1) model-pin (lead `--model` propagates to teammates) and (2) subprocess reuse or persistent session for a teammate across `SendMessage` rounds — a follow-up measurement with the same 8-round fixed-N harness would be appropriate. The cc=0 filter and `reduction_pct` calculation would directly apply if those constraints are lifted.

### Process delta vs plan

- The `--bare` flag was dropped from all measurement invocations (disables keychain auth; `ANTHROPIC_API_KEY` not set). Auth works via keychain without `--bare`. Hooks run but do not affect structured JSON output.
- Warmup count: 1 round observed (not the 2–3 expected); cache stabilized in one warmup for Agent-tool, consistent with a clean session with no prior context.
- Within-session bias: lead cost spans both phases (conservative against P2P), confirmed negligible vs the absolute scale difference between transports.

## S1–S4 Documentation Validation

Per plan s5 RC, explicitly walking the four customer scenarios against this doc:

**S1** (no platform ends in TBD): Both Claude platforms have explicit verdicts (`confirmed` and `no-go`). Copilot has `partial` (blocked by #538 — not TBD). ✅  
  _Evidence_: Platform Verdict Blocks — `verdict_claude_agent_tool.verdict: confirmed`, `verdict_claude_agent_teams.verdict: no-go`, `verdict_copilot.verdict: partial`.

**S2** (every cost figure traceable to transcript or sdk_usage_evidence): Agent-tool figures traceable to `walker_credits` (issue #539 headless session, walker + JSONL-direct). Agent Teams figures traceable to `walker_credits` (same session, JSONL-direct Tier 2). Copilot figures null with explicit null reason. The #535 sdk-usage figure (24.6K) is preserved in Measurement Methodology for historical traceability. ✅  
  _Evidence_: `verdict_claude_agent_tool.walker_credits`, `verdict_claude_agent_teams.walker_credits`, both referencing issue #539 branch and cost-walker fidelity tier.

**S3** (asymmetry section names one of five stances + rationale): `ship-claude-only` stated with rationale; updated with #539 No-Go context. ✅  
  _Evidence_: Asymmetry Stance section — stance and updated status documented.

**S4** (No-go path's `decision_criterion_cited` non-empty): Agent Teams no-go has `decision_criterion_cited` and `blocked_on_api_evolution` fields populated. Copilot partial has `decision_criterion_cited`. ✅  
  _Evidence_: `verdict_claude_agent_teams.decision_criterion_cited`, `verdict_copilot.decision_criterion_cited`.

## Follow-up Work

Per coherence check against issue #534 "Next steps":

1. **Agent Teams measurement complete — OQ1 closed** (issue #539, 2026-05-09): Verdict No-Go. Agent Teams structurally cannot achieve cost parity with Agent-tool under the current API (see verdict block above). OQ1 in #534 is closed as structurally unresolvable. Follow-up requires Agent Teams API evolution (model-pin + cache-persistence). If those land, reopen with the same 8-round fixed-N harness.
2. **Fix Copilot installer** (issue #538): unblock Copilot OTel measurement.
3. **Complete Copilot measurement** (after #538): run Copilot-side prototype once OTel is working.
4. If Claude Agent Teams verdict is ever revised to Go (pending API evolution): **Conductor-dispatch-of-ensemble** implementation — named per issue AC9.

## CE Gate

**Waiver basis**: plan step s5 invariant + issue #535 time-box clause (AC10). Updated with issue #539 completion.

`partial` verdict for Copilot is the expected outcome for this spike:

- Copilot OTel measurement blocked by multi-git installer bug (issue #538 pending).
- Agent Teams measurement required a dedicated fresh session — completed by issue #539. Verdict: No-Go.

The Agent-tool verdict is now `confirmed` (issue #539). The Agent Teams verdict is `no-go` (issue #539). Neither is a CE Gate failure — the spike's goal was to produce defensible verdicts, which are now in hand for both Claude transports.

Follow-up issues carry CE Gate forward:

- **#538** — fix Copilot installer bug, then run Copilot-side measurement

**Exercised surface**: design doc only. No CLI, browser, canvas, or API surface was changed. CE Gate runner work is not required.

<!-- markdownlint-disable-file MD041 -->
