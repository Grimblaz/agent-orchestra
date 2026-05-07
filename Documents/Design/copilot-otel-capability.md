# Copilot OTel Capability Validation

Issue #488 Step 1 validated whether VS Code Copilot Chat can emit enough
OpenTelemetry data to support later Copilot cost attribution work. This is an
exploratory artifact only: no production scripts, skills, tests, or committed
VS Code settings are changed. The local `.vscode/settings.json` capture setup is
intentionally excluded from this artifact.

## Capture Setup

Copilot Chat OTel file export was enabled with `captureContent: false` and
`exporterType: file`. The first attempted outfile value used VS Code variables:
`${userHome}/.copilot-otel/${workspaceFolderBasename}/copilot.jsonl`. That did
not create a file after reload and a fresh Copilot Chat turn.

Changing the outfile to a literal absolute path under the user home produced the
capture. For #488 implementation, arbitrary VS Code variable substitution for
`github.copilot.chat.otel.outfile` should be treated as unsupported. Any
downstream install helper should write a literal per-worktree absolute path when
file export is required.

The raw file is live while OTel export remains enabled. The fixture below is
anchored to the first 129 JSONL lines that existed when Step 1 implementation
began, before this artifact work appended additional records through normal tool
use.

## Sanitized Fixture

Fixture files live under
`.github/scripts/Tests/fixtures/cost-walker-copilot/`:

- `copilot-chat.jsonl` is a compact sanitized JSON-lines fixture derived from the
  raw capture. It preserves representative session, tool-call, inference,
  agent-turn, and metrics shapes.
- `synthetic-reflog.txt` is a deterministic reflog companion for later
  branch/window attribution experiments.

The fixture applies these redaction rules:

- Session identifiers are normalized to `session-001`.
- Trace, span, and response identifiers are normalized to deterministic
  placeholders.
- Timestamps are remapped to deterministic ordered values starting at
  `2026-01-01T00:00:00Z` equivalent Unix seconds.
- Machine-specific paths and user-specific values are omitted.
- Attributes named `gen_ai.prompt`, `gen_ai.completion`, or any key containing a
  content-bearing `content` segment are stripped. None were present in the source
  window with `captureContent: false`.
- Raw `{}` exporter records are excluded. They are valid JSON but carry no schema
  signal for parser behavior; the exclusion is deterministic and documented here.

## Observed Schema And Counts

Source window: first 129 raw JSONL lines.

| Observation | Count / Value |
| --- | --- |
| Parseable non-`{}` records | 67 |
| `{}` records excluded | 62 |
| Invalid JSON lines | 0 |
| `service.name` | `copilot-chat` |
| `service.version` | `0.47.0` |
| Distinct `gen_ai.agent.name` values | `GitHub Copilot Chat` |

Event counts in the source window:

| Event shape | Count |
| --- | ---: |
| `gen_ai.client.inference.operation.details` | 18 |
| `copilot_chat.agent.turn` | 11 |
| `copilot_chat.tool.call` | 22 |
| `copilot_chat.session.start` | 2 |
| Metrics records without `attributes.event.name` | 14 |

Token-bearing record counts:

| Record shape | `gen_ai.usage.*` present | Count |
| --- | --- | ---: |
| `gen_ai.client.inference.operation.details` | yes | 18 |
| `copilot_chat.agent.turn` | yes | 11 |
| `copilot_chat.tool.call` | no | 22 |
| `copilot_chat.session.start` | no | 2 |
| Metrics records without `attributes.event.name` | no | 14 |

The distinct `gen_ai.usage.*` keys were `gen_ai.usage.input_tokens` and
`gen_ai.usage.output_tokens`. Metrics records also expose aggregate
`gen_ai.client.token.usage` histograms with `gen_ai.token.type`, but those are
not per-record `gen_ai.usage.*` fields.

Observed request models were `claude-sonnet-4.6`, `gpt-4o-mini`,
`gpt-4o-mini-2024-07-18`, and `gpt-5.5`. Observed response models were
`claude-sonnet-4-6`, `gpt-4o-mini-2024-07-18`, and `gpt-5.5-2026-04-23`.

Observed tool names in the source window were `list_dir`, `manage_todo_list`,
`mcp_github_issue_read`, `memory`, `read_file`, `run_in_terminal`, and
`tool_search`. Tool-call records carried `gen_ai.tool.name`, `duration_ms`, and
`success`; they did not carry token usage fields.

## OQ Resolutions

OQ1: VS Code variable substitution in `github.copilot.chat.otel.outfile` did not
work for this capture. A hardcoded absolute path did work. Downstream setup
should write literal absolute paths per worktree.

OQ2: The only observed `gen_ai.agent.name` value in this capture window was
`GitHub Copilot Chat`. No mode-specific or specialist-specific agent names were
observed, so downstream code must not invent such values from this fixture.

OQ3: Copilot rates remain null with this footnote: `Copilot per-token rates not
published; cost figures excluded for Copilot rows.`

OQ7: With `captureContent: false`, no `gen_ai.prompt`, `gen_ai.completion`, or
content-bearing keys were observed in the source window. Prompt-size is
structurally unavailable for Copilot in this capture unless a future exporter
adds a dedicated non-content prompt-size attribute.

OQ8: Token usage is present on inference detail records and agent-turn records.
Tool-call records carry tool metadata but no tokens. Metrics records can carry
aggregate token histograms, but they do not use the per-record `gen_ai.usage.*`
shape.

## Downstream Implications

S2 parser work should handle flat JSONL log records with top-level `attributes`,
resource attributes in `resource._rawAttributes`, and metric snapshots in
`scopeMetrics`. It should skip `{}` records deterministically.

S3 cost calculation should preserve Copilot token counts while leaving Copilot
rates and cost values null with the OQ3 footnote.

S7 completeness checks should not require prompt-size for Copilot rows. The
available completeness evidence is token presence, model identity, event shape,
and redaction success.

S9 setup work should avoid VS Code variable templates for the OTel outfile key
and should set `captureContent: false` by default. Redaction validation should
continue checking for prompt, completion, and content-bearing keys before any
fixture or captured sample is committed.
