# Transport Survey — Issue #535

**Research spike:** Transport options for peer-to-peer agent dispatch — Claude Code + Copilot
**Date:** 2026-05-08
**Branch:** feature/issue-535-peer-to-peer-research

---

## 1. Precedent Framework Scan

### LangGraph

**Inter-agent message shape**

LangGraph agents communicate through a shared, append-only state object. The canonical transport is a `messages` key holding a list of typed message objects — `HumanMessage`, `AIMessage`, `ToolMessage` — each carrying `content` (string or list of parts), `name` (optional source agent identifier), and `id`. The `add_messages` reducer appends new messages to the existing list rather than overwriting it. When one agent needs to hand off to another, it emits a `HumanMessage` wrapping the handoff payload, often annotated with a `name` field identifying the originating agent, and control passes via a graph edge or a `Command(goto=...)` return.

In multi-agent configurations (Supervisor or Swarm), the default is that all agent subgraphs write into the same `messages` list shared by the parent graph. Agents can alternatively be given private state schemas with different keys; the private history is then summarized or serialized before being appended to the shared channel.

**Why this shape was chosen**

LangGraph's design constraint is that agents must be composable graph nodes. The state-as-transport model means agent nodes are purely functional transforms over state — no out-of-band sockets or queues. The immutable append-only list gives replay semantics (any node can re-read the full history), keeps the framework's checkpointing mechanism consistent (the state is the checkpoint unit), and decouples sender from receiver. Shared state also satisfies the goal of supporting arbitrary topologies (sequential, parallel, hierarchical) without special-casing any of them.

**Observability**

LangGraph exposes per-agent token usage in `response_metadata` on individual message objects (`input_tokens`, `output_tokens`, `total_tokens`). For cross-agent tracing, LangSmith traces each subgraph call as a child span. Agents in a multi-agent run share one trace when the parent graph passes a `trace_id` through; each agent's calls are grouped as nested spans. Per-agent token counts are therefore visible at the span level via LangSmith, but the core LangGraph library does not expose a first-class per-agent usage summary — that aggregation must be done by the caller by walking `response_metadata` on messages filtered by `name`.

Sources: [LangGraph multi-agent tutorial](https://langchain-ai.github.io/langgraph/tutorials/multi_agent/multi-agent-collaboration/), [LangGraph GitHub](https://github.com/langchain-ai/langgraph), [Langfuse LangGraph integration](https://langfuse.com/guides/cookbook/integration_langgraph)

---

### CrewAI

**Inter-agent message shape**

CrewAI's transport unit is the `Task` result, not a raw message. When an agent completes a task, the output is a structured string (or JSON depending on `output_json` or `output_pydantic` configuration) stored in `TaskOutput`. Downstream agents receive prior task outputs through a `context` list declared on their task — CrewAI automatically interpolates context results into the executing agent's prompt. In hierarchical mode, the manager agent acts as the single hub: it issues sub-task delegations as natural-language prompts and receives structured results back, never exposing the raw inter-agent wire.

There is no user-visible binary or socket protocol between agents. The hub-and-spoke topology enforces that all inter-agent payloads flow through the manager, and the manager's delegation is a string prompt constructed by the framework from the original task goal plus available context.

**Why this shape was chosen**

CrewAI's explicit goal is role-playing orchestration — agents are "crew members" with defined roles, goals, and backstory. The task-result-as-message model keeps the communication surface at the level of natural-language job outputs rather than structured protocol messages. This matches the target user (Python developers building LLM pipelines) and avoids surfacing protocol complexity. The hub-and-spoke constraint (no peer-to-peer) was a deliberate security and predictability decision: restricting the communication graph makes audit and debugging tractable, and avoids issues like message amplification across many agents.

**Observability**

After `crew.kickoff()`, `crew_output.usage_metrics` (or `crew_output.token_usage`) contains aggregate token counts for the entire crew execution — input and output tokens summed across all agents and tasks. Per-task token counts are accessible through individual `TaskOutput` objects when `verbose=True` logging is enabled. Per-agent granularity requires iterating task outputs filtered by `agent`. CrewAI does not emit OTel signals natively; third-party integrations (Langfuse, AgentOps) instrument it via callback hooks.

Sources: [CrewAI docs — Crews](https://docs.crewai.com/en/concepts/crews), [CrewAI GitHub](https://github.com/crewaiinc/crewai), [CrewAI community — per-task token calculation](https://community.crewai.com/t/calculate-the-prompt-token-for-each-and-every-tasks-in-agent/2711)

---

### AutoGen

**Inter-agent message shape**

AutoGen v0.4 (AgentChat) uses a typed `ChatMessage` hierarchy. The concrete types are:

- `TextMessage` — plain text, fields: `source` (agent name), `content` (string), `type`, `id`
- `MultiModalMessage` — text plus media parts
- `StopMessage` — signals conversation termination
- `HandoffMessage` — requests control transfer to a named target
- `ToolCallSummaryMessage` — summarizes tool execution for downstream context

Internal agent events (not used for agent-to-agent communication) are a separate `AgentEvent` union: `ToolCallRequestEvent` and `ToolCallExecutionEvent`. This separation between `ChatMessage` (inter-agent transport) and `AgentEvent` (internal observation stream) was a deliberate v0.4 design choice; v0.2 mixed these in a single list causing observability confusion.

Each `ChatMessage` also carries a `models_usage` field of type `RequestUsage(prompt_tokens, completion_tokens)` when the message was produced by a model call, allowing per-message (and therefore per-producing-agent) token attribution.

Agents communicate asynchronously via an actor model: each agent has a message inbox and `on_messages()` is called with new messages only (not full history), reducing re-submission cost. The full message history is maintained by the team/group-chat runtime, not by individual agents.

**Why this shape was chosen**

v0.4 was rewritten from scratch to address v0.2's observability, scalability, and testability shortcomings. The key constraint was enabling external observers to see both the agent-to-agent communication (ChatMessages) and the internal reasoning events (AgentEvents) separately. Typed messages support static analysis and testing. The actor model with an inbox (rather than shared global state) reduces coupling and supports distributed deployment where agents run on different processes or hosts.

**Observability**

Both `ChatMessage` and `AgentEvent` streams are observable by the caller. Each `TextMessage` carries `models_usage` for per-message token counts. The `TaskResult` returned by a team contains `messages` (the full chat history) and an implied per-agent breakdown when messages are filtered by `source`. AutoGen v0.4 includes OpenTelemetry support for distributed tracing; the October 2025 release contributed multi-agent observability spans to the OTel GenAI semantic conventions working group. Per-agent cost tracking is not built-in (dollar amounts require external rate lookup); the migration guide notes this is planned for a future release (tracked in issue #4835).

Sources: [AutoGen v0.4 blog](https://devblogs.microsoft.com/autogen/autogen-reimagined-launching-autogen-0-4/), [AutoGen docs — agents](https://microsoft.github.io/autogen/stable//user-guide/agentchat-user-guide/tutorial/agents.html), [Migration guide v0.2→v0.4](https://microsoft.github.io/autogen/stable//user-guide/agentchat-user-guide/migration-guide.html)

---

### Inspect (UK AISI)

**Inter-agent message shape**

Inspect is an evaluation framework, not a general-purpose multi-agent runtime. Its multi-agent primitive is `AgentState`, a lightweight wrapper containing:

- `messages`: list of `ChatMessage` objects (conversation history)
- `output`: the `ModelOutput` from the model's most recent generation

Agents in Inspect are implemented as Python functions that receive `AgentState`, run a tool-use loop (calling `generate()` internally), and return an updated `AgentState`. Sub-agent invocation is handled by passing an `AgentState` to a nested agent via a `handoff()` tool call — the sub-agent's result messages are then appended back to the parent's message list. The `TaskState` (the broader evaluation sample context) includes `messages`, `metadata`, and available `tools`; `AgentState` is intentionally narrower.

There is no bespoke binary wire protocol. Agents compose through Python function calls passing `AgentState` objects. For external agents (Claude Code, Codex CLI, Gemini CLI), Inspect wraps the agent behind a standard `Agent` interface that accepts and returns `AgentState`.

**Why this shape was chosen**

Inspect's design constraint is eval reproducibility and auditable logging, not production deployment. The narrow `AgentState` interface was chosen to make agents maximally portable: any function with a `messages`-in / `messages`-out contract can be wrapped as an Inspect agent. This makes it easy to evaluate diverse external agents within the same scaffold. The choice to keep `AgentState` separate from `TaskState` prevents agents from accidentally accessing scorer or dataset metadata.

**Observability**

Inspect writes structured logs to `.inspect_ai/` by default, viewable in the VS Code Inspect Log Viewer. Each evaluation sample gets a `Transcript` tab showing all events in order: LLM calls, tool executions, sub-agent handoffs, and custom `InfoEvent` entries. Token usage is captured per `ModelOutput` (accessible via `output.usage`) and aggregated in the `EvalLog.stats` field at the task level. Sub-agent token usage is included in the parent task's aggregate. Inspect does not expose OTel signals natively; its logging format is its own JSON schema, though third-party OTel wrappers exist.

Sources: [Inspect AISI home](https://inspect.aisi.org.uk/), [Custom Agents — Inspect](https://inspect.aisi.org.uk/agent-custom.html), [Hamel Husain Inspect review](https://hamel.dev/notes/llm/evals/inspect.html)

---

## 2. Platform Transport Analysis

### Claude Code

**Current inter-agent transport: Agent tool (subagent model)**

When a Claude Code session uses the `Agent` tool, it spawns a subagent in a completely separate context window. The parent passes a `prompt` string and an optional `subagent_type` (resolved from `.claude/agents/` or `~/.claude/agents/` YAML frontmatter). The subagent runs its own full conversation — loading CLAUDE.md, MCP servers, and skills independently — and returns a single text result back to the parent as the `Agent` tool's return value. There is no shared message log between parent and subagent. Communication is strictly unidirectional after dispatch: the parent blocks, the subagent works, the result returns.

Subagents cannot spawn further subagents (no nested recursion). Multiple `Agent` tool calls in a single parent turn run in parallel, each in its own context window. The parent sees only the final result string from each subagent; intermediate steps, tool calls, and reasoning are invisible to the parent at runtime (though stored in the subagent's own JSONL transcript under `~/.claude/projects/`).

**Peer-to-peer via Agent Teams (experimental)**

Agent Teams (`CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1`, requires v2.1.32+) provide a distinct bidirectional transport through a mailbox system. Teammates communicate via `SendMessage`, which writes JSON inbox files to `~/.claude/teams/{team-name}/inboxes/{agent-name}.json`. Message fields include `from`, `text`, `summary`, `timestamp`, `color`, and `read` status. Any teammate can message any other by name; the lead assigns names at spawn time.

The shared task list (`~/.claude/tasks/{team-name}/`) provides a further coordination primitive: teammates can claim tasks, mark them complete, and read dependency status. File locking prevents concurrent claim races.

This peer-to-peer capability is explicitly experimental, has known limitations (no session resumption for in-process teammates, no nested teams, lead is fixed), and is not the same as the `Agent` tool subagent model.

**Where SDK-level usage appears**

At the Claude Agent SDK level (TypeScript/Python `query()` function), usage is reported **per-dispatch**: each `query()` call returns its own `ResultMessage` with `total_cost_usd` and a `usage` dict (`input_tokens`, `output_tokens`, `cache_creation_input_tokens`, `cache_read_input_tokens`). A `modelUsage` map on the result provides per-model token breakdowns when multiple models are active. The SDK does not maintain a cross-dispatch session-level total; callers must accumulate `total_cost_usd` across calls manually.

Within Claude Code's interactive sessions, `/usage` reports the running session total. There is no UI-level per-subagent breakdown; subagent costs roll into the parent session's running total from the session interface perspective. The transcript JSONL files per-project-slug (`~/.claude/projects/`) contain per-event usage data consumable by a cost walker (as implemented in `.github/scripts/lib/cost-walker.ps1`).

**Shared message log / external observability**

There is no shared message log observable from outside the running session. Each session writes independently to its own JSONL transcript file. The Agent Orchestra cost walker reads these post-session by walking the transcript events and traversing subagent dispatch chains. There is no live streaming API exposing parent+subagent messages to an external observer during execution.

Sources: [Claude Code sub-agents docs](https://code.claude.com/docs/en/sub-agents), [Claude Code agent teams docs](https://code.claude.com/docs/en/agent-teams), [Claude Agent SDK cost tracking](https://code.claude.com/docs/en/agent-sdk/cost-tracking), [Claude Code costs](https://code.claude.com/docs/en/costs)

---

### Copilot Chat

**Multi-agent transport model**

Copilot Chat in VS Code does not expose a peer-to-peer multi-agent primitive equivalent to Claude Code's Agent tool or Agent Teams. The observable multi-agent pattern is agent-mode invocation of sub-agents through the `runSubagent` tool, producing a parent→child hierarchical span tree — the subagent's `invoke_agent` span appears as a child of the parent agent's `execute_tool` span.

Each Copilot Chat conversation is session-isolated: context is per-request, not shared across sessions. There is no shared message log accessible by multiple simultaneous Copilot agents. When Copilot invokes a specialist (e.g., a coding agent for background tasks), the delegated work runs in its own isolated session; results flow back through the tool result mechanism.

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

Sources: [`Documents/Design/copilot-otel-capability.md`], [`Documents/Design/copilot-cost-collection.md`], [VS Code — Monitor agent usage with OpenTelemetry](https://code.visualstudio.com/docs/copilot/guides/monitoring-agents), [`.github/scripts/lib/cost-walker-copilot.ps1`]

---

## 3. Cross-Platform Parity Assessment

Claude Code and Copilot Chat arrive at multi-agent observability from opposite architectural starting points, producing convergence on token presence but divergence on granularity, transport shape, and branch attribution.

**Where they converge**: both platforms emit per-turn token counts (`input_tokens`, `output_tokens`) attached to the agent interaction record. Both use a model-name field on the token-bearing record, enabling per-model segmentation. Both represent a single agent turn as a discrete bounded unit that can be queried after the fact. The Agent Orchestra cost walker already exploits this convergence: `cost-walker.ps1` and `cost-walker-copilot.ps1` normalize both event sources into the same internal schema (`provider`, `agentType`, `message.usage.*`), and `cost-attribution.ps1` accumulates them into the same port buckets.

**Where they diverge**: Claude Code's usage signal lives in JSONL transcripts written to disk per session, requiring post-session file parsing to reconstruct multi-agent chains. Copilot's usage signal lives in OTel spans emittable live to any OTLP backend, with hierarchical span context that natively encodes parent/child agent relationships. This means Copilot natively exposes call-tree structure (which agent invoked which sub-agent), while Claude Code requires cost-walker graph traversal through subagent JSONL files following `Agent` tool dispatch records. For agent teams, Claude Code adds a mailbox-on-disk layer (`~/.claude/teams/`) with no OTel surface at all.

A second divergence is branch attribution: Claude Code assistant events carry `gitBranch` directly in the JSONL event, while Copilot OTel carries no branch field — attribution requires reflog timestamp correlation. This creates asymmetric attribution confidence: Claude events are deterministically branch-matched; Copilot events are probabilistically matched and can be lost if the reflog is pruned or the session spans a branch switch.

A third divergence is cache visibility: Claude Code exposes `cache_creation_input_tokens` and `cache_read_input_tokens` (the Agent SDK docs and cost walker both handle them). Copilot OTel exposes neither; cache metrics remain null in the normalized event schema.

A peer-to-peer prototype on Claude Code would generate inter-agent messages observable only through post-session JSONL parsing or the experimental mailbox files — no live OTel trace. The same prototype on Copilot would be observable as a `invoke_agent` span tree in real time if an OTLP collector is attached, but Copilot has no equivalent of the `SendMessage` peer-to-peer primitive; the only multi-agent model is the `runSubagent`-tool hierarchy. These differences mean a harness designed to measure both platforms must implement two distinct collection paths and accept that live observability is only available on the Copilot side with current tooling.

---

## 4. Key Implications for Harness Design (s3)

**1. Dual-path collection is unavoidable.**
Claude Code usage comes from JSONL transcript files post-session; Copilot usage comes from OTel JSONL emitted during the session. The harness must implement both `cost-walker.ps1`-style transcript walking (Claude) and `cost-walker-copilot.ps1`-style OTel walking (Copilot). Attempting a single unified collection path will break one platform.

**2. Branch correlation asymmetry requires explicit handling.**
Claude events carry `gitBranch` inline. Copilot events must be attributed via reflog timestamp join. The harness must accept that Copilot attribution can fail (reflog pruned, long sessions spanning branch switches) and degrade to a `claude-only-with-copilot-fallback-warning` coverage state rather than blocking harness output. The existing coverage state model in `copilot-cost-collection.md` already defines these states; the harness should propagate them.

**3. Per-dispatch granularity is Claude Code's ceiling.**
Claude Code's SDK exposes usage per `query()` call. Within Claude Code interactive sessions, there is no per-subagent breakdown at the UI layer — it must be reconstructed by walking the subagent JSONL chain. The harness should track dispatch boundaries (each `Agent` tool invocation) as the attribution unit, matching how `cost-walker.ps1` follows `tool_use` → subagent-JSONL chains.

**4. Peer-to-peer (Agent Teams) has no OTel surface.**
If the prototype uses `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1` and `SendMessage`, the mailbox files (`~/.claude/teams/{team-name}/inboxes/`) are the only observable message record. The harness will need to read these files to reconstruct message exchange graphs. There is no equivalent Copilot primitive — Copilot side of a P2P prototype would have to be simulated through sequential `runSubagent` calls.

**5. Cache and rate asymmetry must be represented as nulls, not zeros.**
Copilot cache metrics are structurally absent (not zero). Copilot cost-per-token rates are unpublished. The harness must preserve this distinction with explicit null fields and the OQ3 footnote ("Copilot per-token rates not published; cost figures excluded for Copilot rows.") rather than defaulting to zero, which would corrupt cost totals and rolling baselines.

**6. Framework precedent favors typed message objects with `source` field.**
AutoGen v0.4's `TextMessage.source`, LangGraph's `name` field on messages, and Inspect's `AgentState.messages` all use a named-agent attribution pattern on each message. If the harness defines its own normalized event schema for peer-to-peer messages, adding a `source_agent` field to each event mirrors the industry-standard approach and enables per-agent aggregation without a separate metadata join.

**7. LangGraph and AutoGen demonstrate that shared-state transport and typed-message transport are the two dominant models.**
LangGraph's shared append-only list vs. AutoGen's actor-inbox model represent the trade-off between replay/checkpointing (LangGraph) and decoupled async dispatch (AutoGen). The Claude Agent Teams mailbox model is closer to AutoGen's actor inbox. The harness should account for the fact that messages may arrive out of order if teammates run concurrently — ordering by `timestamp` from the mailbox JSON is the correct reconstruction key, not creation order.

---

*Sources cited inline above. Key reference documents in repo:*
- `Documents/Design/copilot-otel-capability.md`
- `Documents/Design/copilot-cost-collection.md`
- `Documents/Design/cost-walker-coverage.md`
- `skills/copilot-cost-collection/SKILL.md`
- `.github/scripts/lib/cost-walker.ps1`
- `.github/scripts/lib/cost-walker-copilot.ps1`
