---
name: frame-credit-ledger
description: "Warn-only frame credit-ledger pre-PR hook orchestration. Use when Code-Conductor has just run `gh pr create` and needs to surface frame port-coverage gaps as a non-blocking ledger comment on the new PR, or when a maintainer wants to (re)run the ledger against an existing PR for observation. DO NOT USE FOR: plugin entry-point version-bump guardrails (use `plugin-release-hygiene`), post-merge cleanup or pre-merge strategic assessment (use `post-pr-review`), or any flow that should block PR creation — the ledger is warn-only and never gates the PR."
---

<!-- platform-assumptions: markdown skill guidance for Agent Orchestra; assumes the skill is loaded by Code-Conductor (Copilot or Claude) immediately after `gh pr create` succeeds, and that the orchestrator script `.github/scripts/frame-credit-ledger.ps1` is on disk and runnable under `pwsh`. -->
<!-- markdownlint-disable-file MD041 MD003 -->

# Frame credit-ledger

## When to Use

- Code-Conductor has just run `gh pr create` (or an equivalent PR-creation step) and needs to post the warn-only port-coverage ledger before handing the PR back to the operator.
- A maintainer wants to (re)render the credit ledger comment on an existing PR for observation, without re-running the full conductor flow.
- The same Code-Conductor run is rebuilding context after a smart-resume and needs the ledger to reflect the current changeset's frame port coverage.
- The PR body already carries a `<!-- pipeline-metrics ... -->` block at `metrics_version: 4` (the v4 frame additions sit on top of the inherited v3 base per `frame/pipeline-metrics-v4-schema.md`). Pre-v4 bodies trigger the literal pre-v4 short-circuit notice.

## Purpose

Make frame port-coverage visible as observation, not enforcement. Three customer-framing principles from the issue [#429](https://github.com/Grimblaz/agent-orchestra/issues/429) design intent shape every behavior in this skill:

1. **Surface every gap, silently respect every N/A.** Ports that the changeset triggers but does not credit show up as gaps in the ledger comment. Ports that legitimately do not apply stay silent — the operator is never asked to acknowledge a non-event.
2. **Suggestions, not directives — warn means warn.** The ledger renders a comment and exits. It never blocks `gh pr create`, never fails the conductor flow, and never asks the operator to "fix" anything before merging. Recommendations are recommendations.
3. **Idempotent observation.** Re-running the ledger on the same PR produces the same comment in place (find-or-upsert), so repeated invocations during a long-lived PR never spawn duplicate warnings.

This skill operationalizes the umbrella frame-architecture initiative tracked in [#425](https://github.com/Grimblaz/agent-orchestra/issues/425) and the warn-only pre-PR hook tracked in [#429](https://github.com/Grimblaz/agent-orchestra/issues/429).

## Workflow

Code-Conductor invokes this skill as the final observation step after `gh pr create` succeeds in its post-creation flow. The skill's responsibilities are:

- Run the orchestrator script `.github/scripts/frame-credit-ledger.ps1` once against the freshly-created PR number.
- Treat the orchestrator's output as advisory. A non-zero exit or stderr noise must not block the conductor's PR-handoff.
- Default to warn mode. Enforce mode is reserved for a later sub-issue and is not engaged here.
- Trust the orchestrator's idempotence. The script finds-or-upserts its own comment, so callers do not need to check for an existing ledger first.

The canonical invocation is:

```text
pwsh ./.github/scripts/frame-credit-ledger.ps1 -Pr <N>
```

Per the [#429](https://github.com/Grimblaz/agent-orchestra/issues/429) **D-Ordering-1** judge disposition, this skill deliberately does **not** enumerate the orchestrator's parameter list, the fail-open trigger taxonomy, or any internal helper signatures. Those details live in the script and are the single source of truth. For parameter discovery and failure behavior, read the orchestrator's comment header or run it with `-?` for PowerShell's standard help surface; do not duplicate that surface here.

The conductor's only contract with this skill is:

- Invoke it after PR creation succeeds.
- Pass the new PR number.
- Do not branch on the result. The ledger either posts a comment, posts nothing (pre-v3 short-circuit), or fails open silently. None of those outcomes change the conductor flow.

## Related Guidance

- [`customer-experience/SKILL.md`](../customer-experience/SKILL.md) — CE Gate is a sibling concern. The ledger reports the credit status of any triggered `ce-gate-*` port; it never *runs* CE Gate. Execution stays with the customer-experience skill and the Experience-Owner agent.
- [`plugin-release-hygiene/SKILL.md`](../plugin-release-hygiene/SKILL.md) — separate concern. Release-hygiene fires on plugin entry-point edits and proposes version bumps; the credit-ledger fires on PR creation regardless of whether entry-point files were touched. The two skills are co-resident, not overlapping.
- [`post-pr-review/SKILL.md`](../post-pr-review/SKILL.md) — separate concern. Post-PR-review runs after merge for archival, documentation, and tagging; the credit-ledger runs before merge as a pre-PR observation pass.
- [`Documents/Design/frame-architecture.md`](../../Documents/Design/frame-architecture.md) — the **Pre-PR Hook Contract** section is the design reference for the ledger's behavior shape. The **Adapter Model** section governs why this skill is methodology and not a port-filling adapter.
- Issue [#425](https://github.com/Grimblaz/agent-orchestra/issues/425) — frame-architecture umbrella that tracks the audit → declarations → enforcement arc.
- Issue [#429](https://github.com/Grimblaz/agent-orchestra/issues/429) — the warn-only pre-PR hook that this skill describes.

## Frame Ports Filled By This Skill

None — this skill is methodology, not a port-filling adapter. The credit-ledger orchestrator is the **enforcement** layer for the frame; no port is "filled" by enforcement itself. Per [`Documents/Design/frame-architecture.md`](../../Documents/Design/frame-architecture.md) Adapter Model, ports are filled by skills and agents whose terminal output becomes the credit for that port. The ledger reads those credits, it does not produce one.

## Gotchas

- **Cost telemetry is best-effort and always fail-open.** If the cost libs fail to load (parse error, missing file) or if any step in the cost composition block throws, the orchestrator degrades gracefully: the ledger comment is posted without a Cost Pattern section. The cost pattern never gates or delays PR creation.

- **Cost Pattern section requires the `cost-reduction` label.** The CI presence-check workflow (`cost-pattern-presence-check.yml`) only fires on PRs that carry the `cost-reduction` label. PRs without that label have no CI gate and may have no Cost Pattern section at all (the orchestrator still attempts composition, but there is no CI verification pass).

- **Model key matching in the rate table is exact.** The `cost-rate-table.json` keys must match the model string that appears in `message.model` in the JSONL transcript. If Claude introduces a new model variant (e.g., `claude-sonnet-4-7`) that is not yet in the rate table, cost for that model is set to null and `null_cost_events` increments. Update `cost-rate-table.json` and commit a new version entry when a new model is deployed.

- **Transcript slug derivation is case-sensitive for path segments.** `Get-CostTranscriptSlug` produces slugs like `c--Users-Micah-Code-2-copilot-orchestra` (drive letter lowercased, path segments case-preserved, spaces replaced with dashes). If the Claude projects directory uses a different slug format in practice, adjust the derivation in `cost-walker.ps1` rather than trying to rename directories.

- **Partial or unknown sessions are excluded from rolling baselines.** `excluded_from_rolling_baseline: true` is emitted in the `cost-pattern-data` YAML for any session that did not end with `stop_reason: end_turn`. These entries are skipped by `ConvertTo-CostRollingEntries` and do not contribute to anomaly detection statistics. A PR that ends mid-session (e.g., operator-interrupted) will show the partial-session warning header and will not pollute the rolling baseline.

- **The foundational #467 PR should be annotated as an outlier baseline exclusion.** Pass `-ExcludeReason 'foundational-baseline-pr'` to `Get-SessionCompleteness` at the call site, or annotate the PR comment post-hoc. This prevents the unusually large foundational session from skewing the rolling mean and stddev used by anomaly detection on all future PRs.

## Platform-specific invocation

This skill's methodology is tool-agnostic. Platform-specific routing lives alongside:

- Copilot: [platforms/copilot.md](platforms/copilot.md)
- Claude Code: [platforms/claude.md](platforms/claude.md)
