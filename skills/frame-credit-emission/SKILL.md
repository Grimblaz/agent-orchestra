---
name: frame-credit-emission
description: "Frame credit row emission and deferred credit-input methodology for agents and CE Gate surfaces. Use when an agent or skill needs to write frame credits to the PR-body pipeline-metrics block, or when a pre-PR agent needs to persist a credit-input marker for later harvest. DO NOT USE FOR: predicate evaluation logic (use frame port adapter files), or builder function implementation (use frame-credit-ledger-core.ps1)."
---

# Frame Credit Emission

Reusable methodology for frame credit row emission across all 17 frame ports. Defines the terminal-step contract, credit-input marker schema, and locus-category routing for agents and skills that contribute to the frame ledger.

## When to Use

- When an agent completes a terminal step and must write a credit row to the PR-body pipeline-metrics block
- When a pre-PR agent (Experience-Owner, Solution-Designer, Issue-Planner) must persist a credit-input marker for deferred emission
- When Code-Conductor harvests credit-input markers at PR-creation time
- When CE Gate orchestration evaluates per-surface applicability and emits credits for each surface independently

## Locus Categories

Frame credit emission follows one of four locus categories based on the port's lifecycle position relative to PR creation:

### `agent-post-pr`

Ports owned by specialist agents whose terminal step occurs after PR creation. The agent writes its credit row directly into the `<!-- pipeline-metrics -->` block on the PR body via the appropriate `Build-*CreditRow` function.

**Ports in this category**: `implement-code`, `implement-test`, `implement-refactor`, `implement-docs`, `process-review`

**Terminal-step contract**: Read the port's adapter file from `frame/ports/{port}.yaml`, evaluate the `applies-when` predicate against the changeset, call the matching `Build-*CreditRow` function with port-specific evidence, and upsert the credit row into the PR-body pipeline-metrics block.

**Dedupe contract** (`process-review` only): `Build-ProcessReviewCreditRow` is the canonical emitter. If a `process-review` credit row already exists in the pipeline-metrics block with `status: passed` or `status: not-applicable`, Code-Conductor skips emission (additive-merge rule, D9). Note: the SMC-16 `not-persisted` synthesis path covers only the `review` port (judge-sentinel-driven); it does not extend to `process-review` — no `process-review`-specific sentinel exists.

### Senior Engineer skill-as-adapter credits

For `adapter-type: work` skill adapters, the default executor is `agents/Senior-Engineer.agent.md`. Spine-Runner dispatches Senior Engineer with the planner-selected adapter path, and the Senior Engineer subagent emits the terminal credit row after validation; Spine-Runner verifies the row but does not write it directly.

Credit attribution remains builder-owned. Existing `Build-*CreditRow` functions are unchanged; the work adapter passes its repo-relative adapter path as the builder adapter value and repeats that path in human-readable evidence. For `Build-ImplementCodeCreditRow`, the forward-compatible row key set guarded for #557 is exactly `port`, `adapter`, `status`, `evidence`. The #557 schema migration should preserve this set-equal assertion until the canonical schema intentionally changes.

### `agent-pre-pr`

Ports owned by pipeline-entry agents that complete before any PR exists. These agents use a two-stage deferred-emission pattern:

- **Stage A (agent terminal step)**: Post a credit-input comment alongside the existing completion marker, with shape `<!-- credit-input-{port}-{ID} --> <yaml>...</yaml>`. The YAML payload carries the port-specific evidence the builder needs.
- **Stage B (PR-creation harvest)**: Code-Conductor reads the linked issue's comments at `gh pr create` time, locates `<!-- credit-input-{port}-{ID} -->` blocks for each pipeline-entry port, and calls the matching `Build-*CreditRow` to construct the actual credit rows for the PR-body pipeline-metrics block.

**Ports in this category**: `experience`, `design`, `plan`

**Terminal-step contract**: Post a credit-input marker comment with the required YAML payload shape (see Credit-Input Marker Schema below). Code-Conductor harvests at PR-creation time.

### `skill-only`

Ports owned by skills rather than agents. Code-Conductor owns the selector and invokes the appropriate builder function with evidence from the skill's execution.

**Ports in this category**: `post-pr`, `review`

**Terminal-step contract**: Code-Conductor reads the port's adapter file from `frame/ports/{port}.yaml` and emits the skill-owned credit row for that port. For `post-pr`, call `Build-PostPrCreditRow` with the post-merge checklist outcomes from the `post-pr-review` skill. For `review`, follow the review-credit-emission reference, call `Build-ReviewCreditRow`, and use review-specific evidence such as judge ruling status, reviewed PR context, and persisted review ledger or sentinel details. Upsert the resulting credit row into the PR-body pipeline-metrics block.

### `pr-body-pipeline-metrics`

Ports emitted into the PR-body `<!-- pipeline-metrics -->` block by Code-Conductor or the owning skill after PR creation, outside the specialist-agent terminal-step path.

**Ports in this category**: `release-hygiene`, `post-fix-review`

**Terminal-step contract**: Verify the port row in `credits[]`. `release-hygiene` uses the symmetric-bump state-file contract from the `plugin-release-hygiene` skill. `post-fix-review` uses the review-triggered `adversarial-review` post-fix adapter and may be explicitly skipped when the review trigger is absent.

### `deferred-skill-only`

Formalized trigger-conditional ports whose producer is intentionally deferred. Code-Conductor emits a not-applicable deferred row with `Build-DeferredPortCreditRow`.

**Ports in this category**: `process-retrospective`

**Terminal-step contract**: Verify a `credits[]` row with `status: not-applicable` and evidence beginning with `DEFERRED(#NNN):`; the port remains excluded from the coverage denominator until its `trigger-status` becomes live.

### `ce-gate-per-surface`

CE Gate surface ports, where each surface (CLI, browser, canvas, API) is evaluated independently. Code-Conductor delegates the CE Gate phase to Experience-Owner; for each surface, the `customer-experience` skill's CE Gate orchestration evaluates the surface-touch predicate and either exercises the surface or emits `not-applicable`.

**Ports in this category**: `ce-gate-cli`, `ce-gate-browser`, `ce-gate-canvas`, `ce-gate-api`

**Terminal-step contract**: Each `Build-CeGateCreditRow -Surface {name} -Step {terminal-step-id}` call is its own terminal step with its own integrity check. See "Per-Surface Terminal-Step Contract" below for orchestration-failure handling.

## Port -> Locus Inference

Spine-Runner consumes this table as the authoritative port-to-locus mapping. Add rows in this order so inferred frame walking remains deterministic.

| Add order | Canonical port | Locus | Canonical adapter file |
| --- | --- | --- | --- |
| 1 | `experience` | `agent-pre-pr` | [frame/ports/experience.yaml](../../frame/ports/experience.yaml) |
| 2 | `design` | `agent-pre-pr` | [frame/ports/design.yaml](../../frame/ports/design.yaml) |
| 3 | `plan` | `agent-pre-pr` | [frame/ports/plan.yaml](../../frame/ports/plan.yaml) |
| 4 | `implement-code` | `agent-post-pr` | [frame/ports/implement-code.yaml](../../frame/ports/implement-code.yaml) |
| 5 | `implement-test` | `agent-post-pr` | [frame/ports/implement-test.yaml](../../frame/ports/implement-test.yaml) |
| 6 | `implement-refactor` | `agent-post-pr` | [frame/ports/implement-refactor.yaml](../../frame/ports/implement-refactor.yaml) |
| 7 | `implement-docs` | `agent-post-pr` | [frame/ports/implement-docs.yaml](../../frame/ports/implement-docs.yaml) |
| 8 | `process-review` | `agent-post-pr` | [frame/ports/process-review.yaml](../../frame/ports/process-review.yaml) |
| 9 | `post-pr` | `skill-only` | [frame/ports/post-pr.yaml](../../frame/ports/post-pr.yaml) |
| 10 | `review` | `skill-only` | [frame/ports/review.yaml](../../frame/ports/review.yaml) |
| 11 | `ce-gate-api` | `ce-gate-per-surface` | [frame/ports/ce-gate-api.yaml](../../frame/ports/ce-gate-api.yaml) |
| 12 | `ce-gate-browser` | `ce-gate-per-surface` | [frame/ports/ce-gate-browser.yaml](../../frame/ports/ce-gate-browser.yaml) |
| 13 | `ce-gate-canvas` | `ce-gate-per-surface` | [frame/ports/ce-gate-canvas.yaml](../../frame/ports/ce-gate-canvas.yaml) |
| 14 | `ce-gate-cli` | `ce-gate-per-surface` | [frame/ports/ce-gate-cli.yaml](../../frame/ports/ce-gate-cli.yaml) |
| 15 | `release-hygiene` | `pr-body-pipeline-metrics` | [frame/ports/release-hygiene.yaml](../../frame/ports/release-hygiene.yaml) |
| 16 | `post-fix-review` | `pr-body-pipeline-metrics` | [frame/ports/post-fix-review.yaml](../../frame/ports/post-fix-review.yaml) |
| 17 | `process-retrospective` | `deferred-skill-only` | [frame/ports/process-retrospective.yaml](../../frame/ports/process-retrospective.yaml) |

`auto-na` and `explicit-skip` are adapter variant suffixes (unified convention: `{port}-auto-na-adapter.md` / `{port}-explicit-skip-adapter.md`), not canonical port rows. Do not add them to this table.

`frame-credit-ledger` and `pre-pr-format` are descriptive locus-category aliases from design discussion. They refer to skill-only methodology that runs alongside the ports above, are not canonical ports in `frame/ports/*.yaml`, and Spine-Runner does not directly verify them.

## Credit-Input Marker Schema

Pre-PR agents (`agent-pre-pr` locus category) use credit-input markers for deferred emission. The marker shape is:

```text
<!-- credit-input-{port}-{ID} -->
```

```yaml
port: { port }
adapter: { adapter }
evidence: "{human-readable evidence string}"
```

**Field requirements**:

- `port`: The frame port identifier (e.g., `experience`, `design`, `plan`).
- `adapter`: The adapter reference that produced this credit. Spine-Runner v2 frames use the repo-relative adapter path; legacy pipeline-entry emitters may continue to use builder adapter names such as `work-adapter` or `auto-na` until migrated.
- `evidence`: A flat quoted string describing what the agent observed (e.g., `"issue #123; plan-issue marker posted"`). The harvester passes this string verbatim as the `-Evidence` parameter to the matching `Build-*CreditRow` function. Do **not** use a nested YAML mapping here - the harvester's flat key-value parser will silently drop nested fields.

**Persistence rule**: Post the credit-input marker as a GitHub issue comment immediately after the agent's completion marker comment. Code-Conductor harvests all credit-input markers at PR-creation time by reading the issue's comments and calling the matching builder functions.

**Additive-merge rule**: If the PR-body pipeline-metrics block already contains a credit row for a given port (e.g., from a prior credit-write pass), Code-Conductor skips harvesting the credit-input marker for that port. No double-write, no overwrite.

## Per-Surface Terminal-Step Contract

CE Gate surfaces are evaluated independently. Each surface's credit row is its own terminal step:

1. **Predicate evaluation**: For each surface (`cli`, `browser`, `canvas`, `api`), evaluate the surface-touch predicate (`changeset.touches{Surface}Surface()`).
2. **Surface exercise or N/A**: If the predicate is true, exercise the surface and capture evidence. If false, emit `status: not-applicable`.
3. **Credit emission**: Call `Build-CeGateCreditRow -Surface {name} -Step {terminal-step-id}` with the surface-specific evidence and upsert the credit row.
4. **Orchestration-failure handling** _(planned - wrapper not yet implemented)_: when the orchestration wrapper ships, a crash after partial evaluation will cause it to emit the remaining-surface credits as `status: inconclusive` with `block_kind: orchestration` and `evidence: "orchestration crashed before surface evaluated"`. Until then, manually emit missing-surface rows on crash.

Cycle-aware emission uses `(port, terminal-step-id)` as the additive-merge identity for positive terminal steps. Every `Build-*CreditRow` function accepts optional `-Step`; omit it or pass `0` only for legacy plans and `spine-omitted: plan-too-small` plans, where the row keeps the legacy `(port, 0)` identity. For a spine-backed plan, pass the positive step number from the terminal slice marked for that port. Multiple rows for the same port may coexist only when their positive `terminal-step-id` values differ; an existing row with the same `(port, terminal-step-id)` wins and must not be overwritten.

## Deferred-Port Emission Convention

Ports whose trigger predicate is formalized but deferred to a future issue use `Build-DeferredPortCreditRow` instead of the port-specific builder. The evidence string always begins with `DEFERRED(#NNN):` — this prefix is the migration-detection contract (regex `^DEFERRED\(#\d+\):`).

**When to use**: the port's YAML declares `trigger-status: deferred` and `applies-when: never`. The port is excluded from the coverage denominator until `trigger-status` flips to `live` in the producing issue.

**Example** (`process-retrospective`, deferred to #348):

```yaml
port: process-retrospective
adapter: explicit-skip
status: not-applicable
evidence: "DEFERRED(#348): trigger predicate deferred to #348 (since 2026-05-03); port excluded from coverage denominator until trigger-status flips to live."
```

**Pre- vs post-#348 distinction**: rows with the `DEFERRED(#NNN):` prefix are visually distinguishable from post-cutover rows (which will carry real trigger evidence). Migration scripts detect the prefix and convert deferred rows to live rows when #348 ships its producer.

## Related

- [frame/pipeline-metrics-v4-schema.md](../../frame/pipeline-metrics-v4-schema.md) - Credit row schema
- [skills/session-memory-contract/SKILL.md](../session-memory-contract/SKILL.md) - SMC-17 credit-input marker persistence
- [Documents/Design/frame-architecture.md](../../Documents/Design/frame-architecture.md) - Frame port declarations and predicate DSL
- `.github/scripts/lib/frame-credit-ledger-core.ps1` - Builder functions (`Build-*CreditRow`)

## Gotchas

- Pre-PR agents (Experience-Owner, Solution-Designer, Issue-Planner) cannot write PR-body credits directly because no PR exists yet. They must post a `<!-- credit-input-{port}-{ID} -->` marker with the required YAML payload. Code-Conductor harvests these markers at PR-creation time and calls the matching builder functions to populate the pipeline-metrics block.

## Frame Ports Filled By This Skill

**None**. This is supporting methodology only. This skill declares no `provides:` field and fills no frame port. It documents the emission contract for agents and skills that **do** fill frame ports.
