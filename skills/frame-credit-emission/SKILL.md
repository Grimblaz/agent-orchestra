---
name: frame-credit-emission
description: "Frame credit row emission and deferred credit-input methodology for agents and CE Gate surfaces. Use when an agent or skill needs to write frame credits to the PR-body pipeline-metrics block, or when a pre-PR agent needs to persist a credit-input marker for later harvest. DO NOT USE FOR: predicate evaluation logic (use frame port adapter files), or builder function implementation (use frame-credit-ledger-core.ps1)."
---

# Frame Credit Emission

Reusable methodology for frame credit row emission across all 12 pipeline ports. Defines the terminal-step contract, credit-input marker schema, and locus-category routing for agents and skills that contribute to the frame ledger.

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

### `agent-pre-pr`

Ports owned by pipeline-entry agents that complete before any PR exists. These agents use a two-stage deferred-emission pattern:

- **Stage A (agent terminal step)**: Post a credit-input comment alongside the existing completion marker, with shape `<!-- credit-input-{port}-{ID} --> <yaml>...</yaml>`. The YAML payload carries the port-specific evidence the builder needs.
- **Stage B (PR-creation harvest)**: Code-Conductor reads the linked issue's comments at `gh pr create` time, locates `<!-- credit-input-{port}-{ID} -->` blocks for each pipeline-entry port, and calls the matching `Build-*CreditRow` to construct the actual credit rows for the PR-body pipeline-metrics block.

**Ports in this category**: `experience`, `design`, `plan`

**Terminal-step contract**: Post a credit-input marker comment with the required YAML payload shape (see Credit-Input Marker Schema below). Code-Conductor harvests at PR-creation time.

### `skill-only`

Ports owned by skills rather than agents. Code-Conductor owns the selector and invokes the appropriate builder function with evidence from the skill's execution.

**Ports in this category**: `post-pr`

**Terminal-step contract**: Code-Conductor reads the port's adapter file from `frame/ports/{port}.yaml`, calls `Build-PostPrCreditRow` with the post-merge checklist outcomes from the `post-pr-review` skill, and upserts the credit row into the PR-body pipeline-metrics block.

### `ce-gate-per-surface`

CE Gate surface ports, where each surface (CLI, browser, canvas, API) is evaluated independently. Code-Conductor delegates the CE Gate phase to Experience-Owner; for each surface, the `customer-experience` skill's CE Gate orchestration evaluates the surface-touch predicate and either exercises the surface or emits `not-applicable`.

**Ports in this category**: `ce-gate-cli`, `ce-gate-browser`, `ce-gate-canvas`, `ce-gate-api`

**Terminal-step contract**: Each `Build-CeGateCreditRow -Surface {name}` call is its own terminal step with its own integrity check. See "Per-Surface Terminal-Step Contract" below for orchestration-failure handling.

## Credit-Input Marker Schema

Pre-PR agents (`agent-pre-pr` locus category) use credit-input markers for deferred emission. The marker shape is:

```text
<!-- credit-input-{port}-{ID} -->
```

```yaml
port: {port}
adapter: {adapter-name}
evidence: "{human-readable evidence string}"
```

**Field requirements**:

- `port`: The frame port identifier (e.g., `experience`, `design`, `plan`).
- `adapter`: The adapter name that produced this credit (e.g., `work-adapter`, `auto-na`).
- `evidence`: A flat quoted string describing what the agent observed (e.g., `"issue #123; plan-issue marker posted"`). The harvester passes this string verbatim as the `-Evidence` parameter to the matching `Build-*CreditRow` function. Do **not** use a nested YAML mapping here — the harvester's flat key-value parser will silently drop nested fields.

**Persistence rule**: Post the credit-input marker as a GitHub issue comment immediately after the agent's completion marker comment. Code-Conductor harvests all credit-input markers at PR-creation time by reading the issue's comments and calling the matching builder functions.

**Additive-merge rule**: If the PR-body pipeline-metrics block already contains a credit row for a given port (e.g., from a prior credit-write pass), Code-Conductor skips harvesting the credit-input marker for that port. No double-write, no overwrite.

## Per-Surface Terminal-Step Contract

CE Gate surfaces are evaluated independently. Each surface's credit row is its own terminal step:

1. **Predicate evaluation**: For each surface (`cli`, `browser`, `canvas`, `api`), evaluate the surface-touch predicate (`changeset.touches{Surface}Surface()`).
2. **Surface exercise or N/A**: If the predicate is true, exercise the surface and capture evidence. If false, emit `status: not-applicable`.
3. **Credit emission**: Call `Build-CeGateCreditRow -Surface {name}` with the surface-specific evidence and upsert the credit row.
4. **Orchestration-failure handling** *(planned — wrapper not yet implemented)*: when the orchestration wrapper ships, a crash after partial evaluation will cause it to emit the remaining-surface credits as `status: inconclusive` with `block_kind: orchestration` and `evidence: "orchestration crashed before surface evaluated"`. Until then, manually emit missing-surface rows on crash.

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

- [frame/pipeline-metrics-v4-schema.md](../../frame/pipeline-metrics-v4-schema.md) — Credit row schema
- [skills/session-memory-contract/SKILL.md](../session-memory-contract/SKILL.md) — SMC-17 credit-input marker persistence
- [Documents/Design/frame-architecture.md](../../Documents/Design/frame-architecture.md) — Frame port declarations and predicate DSL
- `.github/scripts/lib/frame-credit-ledger-core.ps1` — Builder functions (`Build-*CreditRow`)

## Gotchas

- Pre-PR agents (Experience-Owner, Solution-Designer, Issue-Planner) cannot write PR-body credits directly because no PR exists yet. They must post a `<!-- credit-input-{port}-{ID} -->` marker with the required YAML payload. Code-Conductor harvests these markers at PR-creation time and calls the matching builder functions to populate the pipeline-metrics block.

## Frame Ports Filled By This Skill

**None**. This is supporting methodology only. This skill declares no `provides:` field and fills no frame port. It documents the emission contract for agents and skills that **do** fill frame ports.
