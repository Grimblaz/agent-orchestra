# Copilot Cost Collection

Issue #488 extends the Cost Pattern telemetry surface from Claude-only capture to
cross-platform Claude plus Copilot capture. The customer problem was visibility:
Copilot-assisted sessions could contribute meaningful implementation, review, or
orchestration work, but they were invisible to the PR Cost Pattern comment. The
implemented design makes that coverage explicit without inventing Copilot costs
or over-attributing sessions when the evidence is incomplete.

## Related Sources

- [copilot-otel-capability.md](copilot-otel-capability.md) is the Step 1
  capability validation artifact. Keep it as evidence for observed OTel shapes,
  redaction behavior, model names, and the literal-outfile finding.
- [cost-walker-coverage.md](cost-walker-coverage.md) remains the Claude-side
  issue-aware coverage design for `/experience`, `/design`, `/plan`,
  `/orchestrate`, and `/code-conductor` transcripts.
- [../../skills/copilot-cost-collection/SKILL.md](../../skills/copilot-cost-collection/SKILL.md)
  documents the local installer and operator-facing setup guidance.

## Architecture

The cross-tool collector keeps the existing Cost Pattern data model and adds a
Copilot event source beside the Claude transcript walker.

1. `skills/copilot-cost-collection/scripts/Initialize-CopilotCostCollection.ps1`
   installs machine-local settings and setup state.
2. `.github/scripts/lib/cost-walker-copilot.ps1` reads Copilot Chat OTel JSONL,
   groups token-bearing records by `session.id`, and joins each session start
   timestamp to the git reflog window for the measured branch.
3. Matched Copilot sessions become normalized assistant events with
   `provider = copilot`, `agentType = GitHub Copilot Chat`, a synthetic
   `cwd = copilot-otel://{workspaceFolderBasename}`, and the branch inferred
   from the reflog.
4. `.github/scripts/frame-credit-ledger.ps1` runs the Claude walker and Copilot
   walker, merges both event arrays, and calls the existing attribution,
   completeness, anomaly, rolling-history, and renderer libraries.
5. `.github/scripts/lib/cost-attribution.ps1` accumulates tokens into the same
   port buckets used for Claude events while preserving per-provider sub-buckets
   when more than one provider contributes to a port.
6. `.github/scripts/lib/cost-pattern-renderer.ps1` renders the existing Cost
   Pattern Markdown table plus embedded `<!-- cost-pattern-data -->` YAML.

This keeps the customer surface stable: readers still see the frame credit
ledger followed by one Cost Pattern section, not a separate Copilot report.

## Setup And Install

Run the installer from the repository root:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File skills/copilot-cost-collection/scripts/Initialize-CopilotCostCollection.ps1 -WorkspacePath . -Yes -NonInteractive
```

The installer is additive and idempotent. It updates VS Code user settings to
enable Copilot Chat OTel file export with `captureContent = false`, writes the
workspace `github.copilot.chat.otel.outfile` setting, creates the OTel parent
directory, writes `.copilot-cost-collection-installed`, and ensures the local
sentinel plus `.vscode/settings.json` are ignored when possible.

The outfile setting must be a literal resolved path such as
`C:/Users/Micah/.copilot-otel/copilot-orchestra/copilot.jsonl`. Step 1 observed
that VS Code variable templates such as
`${userHome}/.copilot-otel/${workspaceFolderBasename}/copilot.jsonl` did not
produce a capture file in this environment. The helper
`Resolve-CostCopilotOutfileTemplate` can resolve templates for diagnostics, but
the installer writes the literal result.

The sentinel and settings are machine-local setup state. They are not durable
workflow state, plan state, review state, or CE evidence. Durable workflow state
continues to live in GitHub issue comments, PR bodies, committed docs, and the
session-memory locations defined by the session-memory contract.

## Attribution And Fidelity

Copilot OTel records do not carry a repository branch. The Copilot walker uses
the earliest timestamp in each token-bearing session and includes that session
only when the timestamp falls inside a target-branch window derived from
`git reflog`. Sessions outside the target window, sessions that cannot be
matched because the reflog is missing or pruned, and ambiguous cross-worktree
sessions are dropped rather than guessed into the current PR.

The normalized Copilot event shape intentionally mirrors what the existing cost
attribution code already accepts:

- `provider`: `copilot`
- `agentType`: `GitHub Copilot Chat`
- `message.model`: the observed request or response model when present
- `message.usage.input_tokens` and `message.usage.output_tokens`: summed from
  inference-detail records, falling back to agent-turn token records when
  inference details are absent
- `message.usage.cache_creation_input_tokens` and
  `message.usage.cache_read_input_tokens`: `null`

Cache metrics remain null because the observed Copilot OTel records do not expose
Claude-style cache creation or cache read counts. Copilot per-token rates also
remain null because published per-token Copilot rates are unavailable. The rate
table keeps Copilot model entries with null rates so token counts are preserved
while cost estimates and rate-dependent fields stay honest.

## Coverage States

The ledger writes coverage metadata into the Cost Pattern YAML and surfaces the
important cases in Markdown.

| State | Meaning |
| --- | --- |
| `claude+copilot` | Claude and Copilot telemetry both contributed events to the run. |
| `copilot-only` | Copilot telemetry contributed events and Claude telemetry did not. |
| `claude-only` | Claude telemetry contributed events with no Copilot fallback signal. |
| `claude-only-with-copilot-fallback-warning` | Claude telemetry contributed events, while Copilot capture was missing, failed, timed out, or had unmapped sessions. |

The `install_status` metadata uses `ok` when the configured OTel JSONL path is
available and `missing-or-fallback` when the path is absent or unusable. Missing
or fallback Copilot data is excluded from cross-tool rolling baselines so a
partial transition period does not contaminate future anomaly comparisons.
Coverage-sensitive anomaly metrics compare only against prior runs with the same
effective coverage class.

## Customer Surface

The customer-facing surface is still the frame credit-ledger Cost Pattern
comment. Cross-tool collection changes the content, not the location:

- The Markdown table keeps the existing columns and port order.
- A port row is labeled `(merged)` when both Claude and Copilot contributed to
  the same port.
- Copilot-only rows show `n/a *` for cache cells when cache metrics are
  unavailable.
- Copilot cost cells are blank when rates are unavailable, with a footnote:
  `Copilot per-token rates not published; cost figures excluded for Copilot rows.`
- The embedded YAML carries `provider_support`, `coverage`, `install_status`,
  `unmapped_session_count`, and per-port `providers` breakdowns for downstream
  tools.
- The fallback footer tells maintainers to run `Initialize-CopilotCostCollection`
  before the next capture when Copilot telemetry is missing or incomplete.

This gives maintainers an honest transition path: Copilot tokens can be visible
before Copilot dollar-cost estimates become available.

## Limits

- The only observed Copilot mode granularity in the Step 1 fixture was
  `GitHub Copilot Chat`; the implementation does not infer specialist or mode
  names that the exporter did not provide.
- Copilot rates are unpublished, so Copilot cost estimates remain null even when
  token counts and models are present.
- Copilot cache creation and cache read metrics are unavailable from the
  observed OTel records.
- Branch attribution depends on reflog availability and the Copilot session
  start timestamp. Long sessions that cross a branch switch are attributed by
  session start, not by each later token event.
- Cross-worktree sessions can be dropped when the single OTel file cannot prove
  which checkout produced the session.
- The collector is fail-open in the PR ledger path. A Copilot walker timeout or
  failure should degrade to a fallback coverage state rather than blocking PR
  creation.

## Validation Evidence

Implementation validation used targeted Pester coverage for the Copilot walker,
installer, attribution, renderer, anomaly, rolling-history, presence-check, and
frame-credit-ledger integration paths. The full Pester suite also passed in this
workspace after the implementation steps.

CE Gate passed after the implementation fix pass. The final structural gate is
expected to remain 11/12 in this branch because `quick-validate.ps1` still hits a
known PSScriptAnalyzer baseline/runtime issue outside the #488 documentation
scope.
