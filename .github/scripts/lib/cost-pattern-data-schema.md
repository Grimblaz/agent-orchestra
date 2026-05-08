# `<!-- cost-pattern-data ... -->` Embedded YAML Schema — Version 1

This document defines the schema for the `<!-- cost-pattern-data ... -->` YAML block embedded in frame-credit-ledger PR comments (issue #467, design D1–D17).

## Schema Versioning

- `schema_version` is always `1` for v1 payloads.
- Additive-only rule (design D12): new fields may be added without a version bump. Readers encountering unknown fields treat them as `null`.
- Breaking changes (removing, renaming, or retyping existing fields) require a new field name or a `schema_version` increment. Existing v1 readers are not expected to handle v2 payloads.

## Top-Level Fields

| Field | Type | Description |
| --- | --- | --- |
| `version` | string | Payload format version string (e.g., `"1"`). |
| `schema_version` | integer | Always `1` for v1. Used by readers to detect format incompatibility. |
| `session_completeness` | string | Completeness indicator for the session (e.g., `"complete"`, `"partial"`, `"unknown"`). |
| `excluded_from_rolling_baseline` | boolean | When `true`, this PR's data is excluded from rolling-baseline calculations (e.g., partial sessions, anomalous runs). |
| `generated_at` | string (ISO-8601) | UTC timestamp when the payload was generated (e.g., `"2026-04-30T12:00:00Z"`). |
| `pr` | integer | GitHub pull request number this payload is attached to. |
| `branch` | string | Git branch name associated with the PR. |
| `provider_support` | array of strings | Additive post-#488 field listing telemetry providers represented by this payload (for example, `["claude", "copilot"]`). Pre-#488 readers default to Claude-only behavior. |
| `coverage` | string | Additive post-#488 coverage tag: `claude+copilot`, `claude-only`, `copilot-only`, or `claude-only-with-copilot-fallback-warning`. Missing v1 values default to `claude-only`. |
| `install_status` | string | Additive post-#488 Copilot collection status, such as `ok` or `missing-or-fallback`. Missing v1 values default to `ok`. |
| `unmapped_session_count` | integer | Additive post-#488 count of Copilot sessions found but not mapped to the current PR branch. Missing v1 values default to `0`. |

## `ports` — Per-Port Token and Cost Breakdown

**Wire format**: YAML array of objects under the top-level `ports:` key. Each entry has a `name` field.

**In-memory format (after parse by `cost-rolling-history.ps1::ConvertFrom-CostPatternYaml`)**: hashtable keyed by port name, values being the per-port objects below. This shape gives consumers (`Get-MetricValue`, `Invoke-CostRegimeCheckpoint`) O(1) port lookup via `$entry.ports.ContainsKey($portName)`.

When authoring code that consumes `Get-CostRollingHistory`'s `entries[].ports`, treat it as a hashtable. When authoring code that emits or reads the wire YAML directly, treat it as an array.

Each port entry:

| Field | Type | Description |
| --- | --- | --- |
| `name` | string | Port name (e.g., `"experience-owner"`, `"solution-designer"`). |
| `tokens.input` | integer | Total input tokens consumed by this port. |
| `tokens.output` | integer | Total output tokens produced by this port. |
| `tokens.cache_creation` | integer | Tokens written to prompt cache for this port. |
| `tokens.cache_read` | integer | Tokens read from prompt cache for this port. |
| `model` | string | Model identifier used for dispatches on this port (e.g., `"claude-sonnet-4-x"`). When mixed models were used, `mixed_regime` is `true`. |
| `cost_estimate_usd` | number | Estimated cost in USD for this port, derived from `cost-rate-table.json`. |
| `dispatch_count` | integer | Number of subagent dispatches attributed to this port. |
| `null_cost_events` | integer | Number of events where cost could not be computed (e.g., unknown model). |
| `cache_read_hit_ratio` | number | Ratio of cache-read tokens to total input tokens (0.0–1.0). |
| `parallel_dispatch_groups` | integer | Number of parallel dispatch groups detected for this port. |
| `mixed_regime` | boolean | `true` when more than one model was used across dispatches on this port. |
| `provider_support` | array of strings | Optional post-#488 provider list for this port. Omitted for ordinary Claude-only rows. |
| `providers` | object | Optional post-#488 per-provider subobjects keyed by provider name. Provider rows preserve provider-local tokens, dispatch counts, costs, cache ratios, and availability flags such as `providers.copilot.cache_metric_unavailable`. Copilot provider rows may omit cache ratio fields when Copilot telemetry cannot supply cache metrics. |

## `orchestrator_overhead` — Orchestrator Token and Cost Breakdown

Object. Captures tokens and cost attributable to the Code-Conductor orchestration layer (not attributed to any specific port).

| Field | Type | Description |
| --- | --- | --- |
| `tokens.input` | integer | Total input tokens for orchestrator turns. |
| `tokens.output` | integer | Total output tokens for orchestrator turns. |
| `tokens.cache_creation` | integer | Tokens written to prompt cache by orchestrator. |
| `tokens.cache_read` | integer | Tokens read from prompt cache by orchestrator. |
| `cost_estimate_usd` | number | Estimated cost in USD for orchestrator overhead. |
| `cache_read_hit_ratio` | number | Ratio of cache-read tokens to total input tokens (0.0–1.0). |

## `dispatches` — High-Level Dispatch Counts

Object.

| Field | Type | Description |
| --- | --- | --- |
| `general_purpose_count` | integer | Dispatches attributed to named frame ports. |
| `unattributed_count` | integer | Dispatches that could not be attributed to any port. |

## `totals` — Session-Wide Aggregates

Object. Sum across all ports and orchestrator overhead.

| Field | Type | Description |
| --- | --- | --- |
| `tokens.input` | integer | Total input tokens for the session. |
| `tokens.output` | integer | Total output tokens for the session. |
| `tokens.cache_creation` | integer | Total cache-creation tokens for the session. |
| `tokens.cache_read` | integer | Total cache-read tokens for the session. |
| `cost_estimate_usd` | number | Total estimated cost in USD for the session. |

## `anomaly_flags[]` — Anomaly Detection Results

Array of objects. Each entry represents a metric that deviated from baseline or checkpoint thresholds.

| Field | Type | Description |
| --- | --- | --- |
| `metric` | string | Metric name that triggered the flag (e.g., `"cost_estimate_usd"`, `"tokens.input"`). |
| `port` | string | Port name the anomaly applies to, or `"totals"` / `"orchestrator_overhead"` for aggregate metrics. |
| `this_value` | number | Observed value for this session. |
| `baseline_mean` | number | Rolling-baseline mean for comparison. |
| `baseline_median` | number | Rolling-baseline median for comparison. |
| `baseline_stddev` | number | Rolling-baseline standard deviation. |
| `baseline_n` | integer | Number of data points in the rolling baseline. |
| `checkpoint_value` | number | Checkpoint reference value (from prior approved PR), if applicable. |
| `vs_baseline` | string | Which comparisons triggered: `"rolling"`, `"checkpoint"`, or `"both"`. |
| `direction` | string | Direction of deviation: `"shrink"` (lower than expected), `"grow"` (higher than expected), or `"informational"` (within threshold but noteworthy). |
| `confidence` | string | Detection confidence: `"high"`, `"medium"`, or `"low"`. |
