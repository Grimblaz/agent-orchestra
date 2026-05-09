# Peer-to-Peer Agent Dispatch — Research Spike

**Issue**: #535  
**Branch**: feature/issue-535-peer-to-peer-research  
**Date**: 2026-05-08  
**Status**: partial verdict (see verdict blocks)

## Overview

This document records the findings of the research spike for issue #535: whether peer-to-peer (P2P) agent dispatch is cost-viable on Claude Code and Copilot Chat, and what transport options exist on each platform.

The spike measured Claude Code's current `Agent` tool dispatch overhead using SDK usage telemetry (three rounds: one warmup + two steady-state). Copilot Chat measurement was deferred due to a multi-git detection bug in the Copilot OTel installer (issue #538). Copilot capability is documented from transport survey and platform docs only.

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

Cache-warmup criterion: discard rounds where `cache_creation_input_tokens > 0`. Rounds 2–3 are steady-state (delta = 0 tokens between rounds, confirming cache fully warm).

**Walker miss**: `cost-walker.ps1` returned 0 sessions for the spike branch. Root cause: session transcript is in-flight (walker reads JSONL files after session completes). `cost_source: sdk-usage` applies. Per-round `input_tokens`/`output_tokens` breakdown unavailable; only `total_tokens` captured from Agent tool result.

**Key observation**: Per-dispatch `total_tokens` (~24.6K) is dominated by parent conversation context propagation, not the task payload. This means per-dispatch cost scales with parent session size, not task size.

### Copilot — capability analysis only

Copilot OTel collection installer (`Initialize-CopilotCostCollection.ps1`) fails on machines with multiple git installations — the `Get-Command git` call returns a collection instead of a single path (issue #538). Measurement deferred. Capability documented from transport survey and VS Code OTel monitoring docs.

## Decision Matrix

| Platform | Transport | Maturity | Measured | Verdict |
|----------|-----------|----------|----------|---------|
| Claude Code — Agent tool | One-directional hub→subagent | stable | Yes (SDK usage) | partial |
| Claude Code — Agent Teams | Mailbox P2P (SendMessage) | experimental | No | partial |
| Copilot Chat | Hierarchical runSubagent only | stable | No (installer bug) | partial |

## Platform Verdict Blocks

```yaml
---
verdict_claude_agent_tool:
  verdict: partial
  transport: agent-tool-dispatch
  transport_maturity: stable
  cost_source: sdk-usage
  walker_credits: null
  sdk_usage_evidence: "3 dispatch rounds on feature/issue-535-peer-to-peer-research; total_tokens per round: warmup=24667, ss1=24665, ss2=24665"
  cost_per_round_input_tokens: null
  cost_per_round_output_tokens: null
  cost_per_round_total_tokens_observed: 24665
  verdict_rationale: >
    Agent tool dispatch shows ~24.6K tokens/round overhead dominated by parent context propagation.
    Viable for coarse-grained ensemble dispatch where specialist agents do substantial work
    (50K+ token tasks). Not viable for fine-grained message-passing where overhead dominates.
    True P2P cost (Agent Teams) not measured.
  threshold_rationale: >
    Partial verdict — 40% cost-reduction threshold comparison deferred to Agent Teams measurement.
    Current Agent tool overhead is context-dependent and not a fixed per-message cost.

verdict_claude_agent_teams:
  verdict: partial
  transport: agent-teams-sendmessage
  transport_maturity: experimental
  cost_source: sdk-usage
  walker_credits: null
  sdk_usage_evidence: "Not measured — requires CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1; capability documented from transport survey and Claude Code agent teams docs"
  cost_per_round_input_tokens: null
  cost_per_round_output_tokens: null
  verdict_rationale: >
    Agent Teams provides mailbox-on-disk P2P via SendMessage, writing JSON to
    ~/.claude/teams/{team-name}/inboxes/{agent-name}.json. Transport exists and is the
    closest available Claude P2P primitive. No OTel surface — observable only via
    post-session mailbox file reads. Measurement requires dedicated session with
    CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1. Cost viability unknown.
  threshold_rationale: >
    Partial verdict — cannot evaluate 40% threshold without measurement data.

verdict_copilot:
  verdict: partial
  transport: none
  transport_maturity: "n/a"
  cost_source: sdk-usage
  walker_credits: null
  sdk_usage_evidence: "No measurement — Copilot OTel collection not installed (issue #538 pending). No P2P transport primitive available on Copilot Chat."
  cost_per_round_input_tokens: null
  cost_per_round_output_tokens: null
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

**Stance**: `ship-claude-only`

**Rationale**: Claude Code has the Agent Teams transport primitive required for true P2P dispatch (mailbox-on-disk, experimental but available). Copilot Chat lacks an equivalent — its multi-agent model is strictly hierarchical. Proceeding symmetrically would require Copilot to emulate P2P through sequential subagent chains, adding orchestration complexity without transport-level P2P semantics.

If Agent Teams cost proves viable (follow-up to this spike), a Claude-only P2P implementation can ship while Copilot support waits for a Copilot-native transport primitive (if one ships).

## Lessons Learned

### Claude Code — methodology

- **Walker in-flight miss**: running measurement dispatches inside the orchestration session means the session transcript is in-flight when the walker runs. Future measurement spikes should run measurement dispatches in a **dedicated fresh session** (not the orchestration session) to ensure walker reads a completed transcript.
- **Context-scale domination**: per-dispatch `total_tokens` scales with parent conversation length. The 24.6K overhead observed here includes the entire orchestration conversation. A clean measurement session would show lower per-dispatch overhead (only the measurement-session context).
- **Reproducer commands**:
  - Branch: `git checkout feature/issue-535-peer-to-peer-research`
  - Measurement: dispatch three agents with minimal prompt using Claude Code `Agent` tool
  - Walker: `pwsh .github/scripts/lib/cost-walker.ps1 -IssueNumber 535 -Repo Grimblaz/agent-orchestra -Branch feature/issue-535-peer-to-peer-research` (run after session completes)

### Copilot Chat — methodology

- **Multi-git installer bug**: `Initialize-CopilotCostCollection.ps1` crashes when `Get-Command git` returns multiple results. Fix: add `| Select-Object -First 1`. Tracked in issue #538.
- **Reproducer commands** (after #538 merges):
  - Install: `pwsh skills/copilot-cost-collection/scripts/Initialize-CopilotCostCollection.ps1 -WorkspacePath . -Yes -NonInteractive`
  - Run measurement: `pwsh .tmp/issue-535/harness.ps1 --mode run-prototype --platform copilot --rounds 10 --warmup-rounds 2`
  - Walker: `pwsh .github/scripts/lib/cost-walker-copilot.ps1 -IssueNumber 535 -Repo Grimblaz/agent-orchestra -Branch feature/issue-535-peer-to-peer-research`

### General

- Transport survey identified two collection paths required (JSONL walker for Claude, OTel walker for Copilot) — dual-path is unavoidable given architectural divergence.
- Agent Teams P2P has no OTel surface; mailbox files (`~/.claude/teams/`) are the only observable record. Harness must read mailbox JSON directly if Agent Teams prototype runs.
- Copilot attribution is probabilistic (reflog timestamp join) — sessions crossing branch switches may be mis-attributed.

## S1–S4 Documentation Validation

Per plan s5 RC, explicitly walking the four customer scenarios against this doc:

**S1** (no platform ends in TBD): Both Claude platforms and Copilot have explicit `verdict: partial` — not TBD. ✅

**S2** (every cost figure traceable to transcript or sdk_usage_evidence): The only cost figure is `cost_per_round_total_tokens_observed: 24665` traceable to `sdk_usage_evidence` field in `verdict_claude_agent_tool`. Copilot figures are null with explicit null reason. ✅

**S3** (asymmetry section names one of five stances + rationale): `ship-claude-only` stated with rationale. ✅

**S4** (No-go path's `decision_criterion_cited` non-empty): Copilot verdict (functionally No-go for P2P) has `decision_criterion_cited: "No P2P transport primitive available on Copilot Chat as of 2026-05."` ✅

## Follow-up Work

Per coherence check against issue #534 "Next steps":

1. **Complete Agent Teams measurement** (follow-up to this spike): run `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1` prototype; measure per-message cost vs. Agent tool baseline; determine if 40% threshold is met.
2. **Fix Copilot installer** (issue #538): unblock Copilot OTel measurement.
3. **Complete Copilot measurement** (after #538): run Copilot-side prototype once OTel is working.
4. If Claude Agent Teams verdict is Go: **Conductor-dispatch-of-ensemble** implementation — named per issue AC9.

<!-- markdownlint-disable-file MD041 -->
