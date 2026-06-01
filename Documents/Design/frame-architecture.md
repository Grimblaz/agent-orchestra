# Design: Frame Architecture for Pipeline Enforcement

> **Status**: Living V2 design — revised after walking the model against four historical PRs (#411, #415 post-thin/fat; #286, #338 pre-thin/fat). Audit findings remain the target architecture; current shipped behavior now includes the first frame validator slice.
>
> **Author context**: Originally drafted in the Experience-Owner role during exploratory framing. Subsequent sub-issue work updates current-state sections as behavior ships.

---

## Summary

Agent Orchestra delivers customer-visible work through a pipeline of phases (experience framing, design, plan, implement, review, CE Gate, post-PR). Today, whether each phase actually fires on a given PR depends on **agent prose interpretation** of conductor rules — and since the thin-agents/fat-skills split, prose-only enforcement has drifted: phases get skipped silently and the operator can only detect the gap by manual audit after the fact.

This design introduces a **frame** — a hexagonal-architecture-style contract that declares the required phases as **ports**, allows multiple **adapters** (skills/sub-skills) to fill each port, captures completion as **credits** in a structured PR ledger, and **enforces** completion via a pre-PR hook that blocks PR creation if any port lacks a credit. The frame separates **what must happen** (deterministic, declared in port files) from **how it happens this time** (judgment, contextual selection of an adapter), removing the prose-trust spine while preserving agent flexibility.

The first deliverable is **audit-only**: build the credit ledger format, back-derive credits from existing markers across recent PRs, and report the actual gap rate per port. Enforcement comes after the audit shapes priorities.

---

## Customer Framing

### Who the customer is

Two journeys, both currently degraded:

- **Operator** — the human running `/orchestrate`, `/plan`, `/design`, `/experience`, `/orchestra:review`, etc. Wants confidence that "all the rigor I designed in" actually happens for each PR.
- **Maintainer** — the human adding a new skill or capability. Wants to declare a new adapter and have it discoverable by the frame without hand-editing conductor prose.

### Problem statement

> *"I launch a flow expecting end-to-end rigor. Mid-flow or post-PR I realize step X never fired. There is no way, before merging, to tell whether a PR ran the full pipeline. Every PR becomes a manual audit."*

Since the thin-agent / fat-skill split, the spine that says **"for this kind of change, these things must happen"** got distributed across prose and stopped being load-bearing. Skills are smaller and more reusable, but enforcement evaporated.

### Customer journeys

| Journey | Today | Target |
|---|---|---|
| Launch flow on a feature issue | Conductor narrates phases; some quietly don't fire | Frame manifest declares 13 ports; each port either gets a real credit, an auto-not-applicable credit, or an explicit-skip credit with justification |
| Add a new specialist skill | Edit Code-Conductor prose, hope the right judgment branch fires | Skill declares `provides: <port>` in frontmatter; frame validator confirms port-adapter consistency on startup; conductor prose untouched |
| Audit a past PR for completeness | Read every conductor narration; reconstruct from issue markers | Read one credit-ledger comment on the PR; every port has an entry with status, adapter, evidence link |
| Stop a flow mid-review | Orphan ledgers exist but PR is shippable | Orphan ledgers exist; gate blocks PR until terminal credit (judge ruling) is written |

### Design intent (in customer terms)

- **No silent gaps.** Every port in the frame appears in every PR's credit ledger — passed, failed, skipped, or not-applicable. The operator can never wonder "did X run?" because the absence of a credit is itself impossible.
- **Justification is first-class.** Skipping a port requires a reason that travels with the PR and is challengeable in review.
- **Selection is judgment, enforcement is mechanical.** The agent picks which adapter is right for the change. The hook only checks that some adapter produced a credit. Trust the agent to choose; don't trust prose to remember.
- **The frame is additive.** Existing markers, existing skills, existing agents continue to work. The frame discovers and aggregates rather than rewriting.

### CE Gate readiness

This is meta-infrastructure (work about how work happens). Direct CE Gate exercise is limited:

- **Functional surface**: the credit ledger comment on a real PR — does it parse, does it render, does it block correctly?
- **Intent surface**: does an operator looking at a blocked PR understand what's missing and how to recover?
- **Negative surface**: does the gate fail-open or fail-closed under malformed ledgers, missing port files, hook errors?

Detailed CE scenarios are deferred until the audit-only sub-issue produces a concrete ledger format to exercise.

---

## Vocabulary

| Term | Definition |
|---|---|
| **Frame** | The contract — "what a complete change looks like." Encoded as a directory of port files. |
| **spine** | The durable plan-routing index written with an implementation plan. It maps frame ports to implementation slices and gives Code-Conductor a compact handoff surface for specialist dispatch. |
| **slice** | One addressable implementation-plan step or dependency shard referenced by the spine. A slice carries the step's execution mode, requirement contract summary, dependencies, AC references, and terminal/cycle markers needed for dispatch without loading the whole plan. |
| **coverage-manifest** | The spine's declaration of whether port-to-slice coverage is complete or intentionally exploratory, including the required reason when coverage uses the exploratory escape hatch. |
| **Port** | A required slot in the frame, corresponding to a question a customer would ask about a PR (e.g., "was this reviewed?"). |
| **Adapter** | A skill, sub-skill, or agent step that can fill a port (e.g., `agents/Code-Smith.agent.md`, `skills/adversarial-review/adapters/standard.md`). |
| **Selector** | The agent's judgment about which adapter to plug in for this change, based on adapter `applies-when` predicates. |
| **Credit** | Persisted, machine-readable evidence that a port was filled (or skipped with justification). One credit per port per PR. |
| **Credit ledger** | A single structured PR comment listing every port's credit. The pre-PR hook reads this. |
| **Gate** | The pre-PR hook that blocks PR creation if any port in the frame lacks a credit. |
| **Auto-N/A adapter** | A special adapter per port that fires when a declarative predicate matches "this PR has nothing for this port to do," writing a `not-applicable` credit. |
| **Explicit-skip adapter** | A special adapter per port that requires an operator/agent to supply a justification. Writes a `skipped` credit. The escape hatch for cases predicates don't capture. |
| **Terminal-step rule** | The credit for a multi-stage adapter is written by the *terminal* step (the one that produces the customer-relevant outcome), not by intermediate steps. |
| **Trigger-conditional port** | A port that only applies when a triggering signal occurs in the changeset or another port's output (e.g., `release-hygiene` fires when plugin entry-point files change; `post-fix-review` fires only when `review` finds a Critical/High; `process-review` fires only when CE Gate finds a defect). Distinct from always-applies. |
| **Inconclusive credit** | A credit-status value distinct from `skipped` and `not-applicable`. Used when an adapter could not complete because of an environmental constraint (e.g., browser tools unavailable, runtime surface unreachable). Recoverable; gate may treat as soft-block depending on port configuration. |

### Port-naming principle

A port corresponds to **a question a customer would ask about a PR**. Stages internal to an adapter (e.g., review's prosecute → defend → judge) are *not* separate ports because they don't answer separate customer questions — the judge ruling *is the answer* to "was this reviewed?".

This is the test for whether to split or merge a port.

---

## Spine schema (v1 and v2)

The frame spine is a plan-routing and context-sharing block, not a replacement for the PR body's pipeline metrics block.

1. **Field name**: spine blocks use `spine_schema_version: 1` or `spine_schema_version: 2`. Version 2 is additive and remains wire-compatible with v1 consumers that ignore unknown slice fields. Spine blocks do not use `frame_version`; the existing pipeline metrics `frame_version: 1.0` field remains unrelated.
2. **Canonical form**: port keys are sorted alphabetically. Port values use inline lists such as `[s2, s5]`. Flow-style bracket entries may carry cycle markers such as `s8#cycle:3#terminal`; block-scalar slice metadata uses the alternate `cycle: N` field. Canonical blocks have no trailing whitespace and use ISO-8601 UTC timestamps in `generated_at`.
3. **Cycle marker grammar**: inline slice tokens use `sN[#cycle:N][#terminal]`. `cycle:N` is omitted when `N=1`. Block-form slice metadata uses explicit `terminal: true` for terminal steps. Ordering is the list position, not the numeric slice ID.
4. **Slice adapter hint (v2)**: v2 slice metadata may include an optional `adapter: {repo-relative path}` scalar. For executable Spine-Runner frames, the value is a repo-relative adapter file path such as `agents/Code-Smith.agent.md`, `skills/frame-credit-emission/SKILL.md`, or `skills/{skill}/adapters/{adapter}.md`; short adapter IDs are not resolved through a separate registry. The parser preserves this value as `AdapterRaw` and exposes non-empty values as `Adapter`. The field remains optional for legacy and non-runner consumers: v2 slices without `adapter:` remain valid for predicate-based selection, but Spine-Runner needs a resolvable path to execute a slice.
5. **Slice executor hint (v2)**: v2 slice metadata may include optional `executor:`. Legal values use the exact enum literal `agents/*.agent.md path | inline`. When absent, the executor is derived from the adapter frontmatter's `adapter-type:` enum literal `work | predicate`: `work` defaults to `agents/Senior-Engineer.agent.md`, and `predicate` defaults to `inline`. `executor: none` is deferred and rejected by current validation.
6. **Exploratory coverage escape hatch**: `coverage: exploratory — {reason}` is allowed only when the reason is present. That reason is surfaced as a ledger row so reviewers can challenge incomplete routing coverage.
7. **Plan-size threshold D8**: an implementation step means a step whose Execution Mode is `serial` or `parallel` and whose RC contains a GREEN code or test action. Adversarial review, CE Gate, and post-retrospective steps do not count toward the threshold.
8. **Metrics version bump policy**: adding `spine-stale-fallback-count`, `dispatch-fallback-events[]`, and `dispatch-cost-samples[]` does not bump `metrics_version` because they are additive optional v4 fields. Likewise, the optional sixth key `provider:` on `dispatch-cost-samples[]` rows is additive and does not bump `metrics_version`; parsers accept 5-key and 6-key rows. Known values for `provider`: `claude` | `copilot`; additional values tolerated additively per #467 D12. See `frame/pipeline-metrics-v4-schema.md` for the authoritative `dispatch-cost-samples[]` row contract.
9. **D9 normalized-diff `generated_at` elision**: for D9 model-switch diff comparison, hash-elide the `generated_at:` line inside frame-spine blocks so identical content does not append duplicate durable handoff comments.

Example v2 canonical shape:

```yaml
<!-- frame-spine
spine_schema_version: 2
generated_at: 2026-05-04T14:30:00Z
coverage: complete
ports:
  ce-gate-api: [s8#cycle:3#terminal]
  implement-code: [s2, s5]
  implement-test: [s3]
slices:
  s2:
    execution_mode: serial
    adapter: agents/Code-Smith.agent.md
    rc: GREEN code action
    ac_refs: [AC1, AC2]
    depends_on: []
    cycle: 1
  s5:
    execution_mode: parallel
    adapter: agents/Code-Smith.agent.md
    rc: GREEN code/test action
    ac_refs: [AC4]
    depends_on: [s2]
    cycle: 2
  s8:
    execution_mode: serial
    adapter: skills/customer-experience/adapters/ce-gate-api.md
    rc: CE Gate evidence capture
    ac_refs: [AC9]
    depends_on: [s5]
    cycle: 3
    terminal: true
-->
```

Concise skill-as-adapter `frame-slice` block shape:

```markdown
<!-- frame-slice
id: s2
provides: [implement-code]
adapter: skills/implementation-discipline/adapters/implement-code-adapter.md
executor: agents/Senior-Engineer.agent.md
ac_refs: [AC5]
coverage: GREEN code action
-->
```

---

## Canonical Port List (V2)

**Seventeen ports**: 13 always-applies, 3 trigger-conditional, and 1 deferred decision port. Flat list — sub-ports rejected during design (parent nodes added bookkeeping without structural meaning). Display can group by name prefix without altering the gate's data model.

### Always-applies ports (13)

| Port | Adapter family today | Auto-N/A rule (declarative) |
|---|---|---|
| `experience` | Experience-Owner upstream framing | `changeset.complexity == 'trivial'` |
| `design` | Solution-Designer 3-pass exploration | `changeset.complexity == 'trivial'` |
| `plan` | Issue-Planner | `changeset.complexity == 'trivial'` |
| `implement-code` | Code-Smith | no source files changed |
| `implement-test` | Test-Writer | no testable code changed |
| `implement-refactor` | Refactor-Specialist hub flow; refactoring-methodology skill-as-adapter for `/spine-run` | no touched-area debt above threshold |
| `implement-docs` | Doc-Keeper | no behavior or interface in docs changed |
| `review` | Code-Critic + Code-Review-Response (variants: standard, lite, judge-only, proxy-github) | (always applies) |
| `ce-gate-cli` | CLI-surface scenario exercise | CLI surface not touched |
| `ce-gate-browser` | Browser-surface scenario exercise | web UI not touched |
| `ce-gate-canvas` | Canvas-surface scenario exercise | canvas surface not touched |
| `ce-gate-api` | API-surface scenario exercise | API surface not touched |
| `post-pr` | post-pr-review checklist | (always applies) |

### Trigger-conditional ports (3)

These ports activate when their trigger signal appears. If the trigger does not fire, trigger absence is the N/A evidence; no separate auto-N/A adapter file is declared.

| Port | Trigger | Adapter family today |
|---|---|---|
| `release-hygiene` | Plugin entry-point or distributed plugin files changed | plugin-release-hygiene |
| `post-fix-review` | `review` credit contains a sustained Critical or High finding | Code-Critic post-fix prosecution |
| `process-review` | CE Gate credit shows a sustained defect (`ce_gate_defects_found > 0`) | Process-Review |

### Deferred decision port (1)

| Port | Current status | Adapter family today |
|---|---|---|
| `process-retrospective` | `formalized-skeleton-deferred-to-348`; trigger predicate deferred to #348 | `skills/process-retrospective/SKILL.md` (deferred skeleton; live adapter authored by #348) |

### Revisions from V1 → V2 (driven by audit)

- Dropped `scope.isHotfix` from `experience`/`design`/`plan` auto-N/A predicates. Audit showed PR #415 (a bug fix) ran all three. Trivial-complexity is the only reliable predicate.
- Added `release-hygiene` as a trigger-conditional port for plugin entry-point and distributed plugin file changes.
- Added `post-fix-review` port. PR #286 ran it explicitly; today it lives inside `review`'s prose. It has a distinct trigger and scope, so it deserves its own credit.
- Added `process-review` as a trigger-conditional port.
- `process-retrospective` formalized as a trigger-conditional port with a deferred-skeleton pattern (issue #443). The port is declared in `frame/ports/process-retrospective.yaml` with `trigger-status: deferred` and `trigger-deferred-to: '#348'`. Skill skeleton at `skills/process-retrospective/SKILL.md`; trigger predicate and live adapter authored by #348. Until #348 ships, the port emits `not-applicable` via `Build-DeferredPortCreditRow` and is excluded from the coverage denominator.

Notes:

- Always-applies ports appear in every PR's ledger as passed, failed, skipped, or not-applicable. Trigger-conditional ports appear when triggered or when trigger absence is recorded by the eventual evaluator.
- For ports with multiple work-adapter variants (today, only `review`), the SKILL.md acts as the adapter directory:

  ```text
  skills/adversarial-review/
    SKILL.md            # describes the port + lists adapters
    adapters/
      standard.md       # provides: review, applies-when: changeset.totalLines >= 200 and not scope.isReReview and not scope.isProxyGithub
      lite.md           # provides: review, applies-when: changeset.totalLines < 200 and not scope.isReReview and not scope.isProxyGithub
      judge-only.md     # provides: review, applies-when: scope.isReReview
      proxy-github.md   # provides: review, applies-when: scope.isProxyGithub
  ```

- Single-adapter ports declare in the owning `.agent.md` or `SKILL.md`; companion auto-N/A and explicit-skip declarations live in `skills/<skill>/adapters/` using the unified `{port}-auto-na-adapter.md` / `{port}-explicit-skip-adapter.md` suffix convention.

---

## Adapter Model

### Adapter declaration

Adapters declare port intent in frontmatter on the file that fills the port:

```yaml
---
name: review-lite
provides: review
applies-when: changeset.totalLines < 200 and not scope.isReReview and not scope.isProxyGithub
---
```

Explicit-skip adapters add `reason-required: true` and omit `applies-when` because they are invoked manually with a visible justification.

Work and predicate adapter files use the `adapter-type:` enum literal `work | predicate`. Single-variant work adapters follow `skills/{skill}/adapters/{port}-adapter.md`; multi-variant ports keep selector-named files under `skills/{skill}/adapters/` and distinguish variants with `applies-when:`. The #559 rename sweep owns remaining terminology cleanup outside the #552 Senior Engineer + skill-as-adapter slice.

The current frame validator ships as `.github/scripts/frame-validate.ps1`, backed by `.github/scripts/lib/frame-validate-core.ps1` and `.github/scripts/lib/frame-predicate-core.ps1`. `quick-validate.ps1` aggregates it as `FrameValidator`, so the validator passes or fails with the existing structural validation suite rather than adding a separate CI lane.

The first shipped validator slice is intentionally symmetry-only plus predicate parse-only:

- Port names come from `frame/ports/*.yaml` filename stems. The YAML body is opaque to the validator.
- Adapter discovery scans `agents/*.agent.md`, `agents/*.md` excluding `.agent.md`, `commands/*.md`, `skills/*/SKILL.md`, and direct `skills/*/adapters/*.md` files.
- Every discovered adapter `provides:` value must match a `frame/ports/*.yaml` stem. A port with no adapter declaration is allowed in this slice; coverage strictness waits until adapter declarations and enforcement semantics are in place.
- If `frame/ports/` is missing, adapter symmetry passes with informational detail and predicate parsing still runs.
- Frontmatter handling is deliberately lightweight. It accepts the scalar, inline-list, indented-list, comment, and block-scalar forms used by adapter declarations, but it is not a full YAML parser.

### Declaration asymmetry

Port-filling skills and agents declare `provides:`. Supporting skills loaded only as methodology do not. Use the credit-author/output test: if the skill or agent produces the terminal output that becomes the credit for a port, it declares `provides:`; if it only supplies reusable guidance to another adapter, such as `session-memory-contract`, `routing-tables`, or `subagent-env-handshake`, it stays declaration-free.

Two `provides:`-less supporting methodologies can stack when their load-order relationship is non-trivial. `solution-authoring` and `upstream-onboarding` are the canonical example: both are declaration-free, but their load order is explicit — `solution-authoring` fires first to classify decisions before `upstream-onboarding` surfaces inherited context. That ordering is declared in the agent body dispatcher, not in either skill, preserving skill independence while keeping the stacking contract auditable.

### Three adapter types per port

| Type | Count per port | Purpose |
|---|---|---|
| **Work adapter** | >=1 for live ports | Does the actual thing. Has positive `applies-when` when the port is conditional or variant-bearing. |
| **Auto-N/A adapter** | 0 or 1 | Fires when declarative rule matches "nothing to do." Trigger-conditional ports use trigger absence instead and do not declare auto-N/A files. |
| **Explicit-skip adapter** | exactly 1 for each non-deferred port | Operator/agent invokes with `reason`. Writes `skipped` credit. Justification is visible in PR review and challengeable. |

Unified filename convention: predicate adapters use `{port}-auto-na-adapter.md` and `{port}-explicit-skip-adapter.md` (suffix form). The filename suffix encodes the variant; `adapter-type: predicate` frontmatter declares the work-vs-predicate axis. Filename suffix is the canonical variant signal; on any drift, filename governs.

`process-retrospective` is the only deferred port. It has a formalized-skeleton adapter (`skills/process-retrospective/SKILL.md`) but no live work adapter or auto-N/A adapter. The explicit-skip adapter (`skills/process-retrospective/adapters/process-retrospective-explicit-skip-adapter.md`) is declared but inactive until the trigger flips to live in #348.

### Where to declare

| Adapter type | Declaration location |
|---|---|
| Agent-owned work adapter | Canonical `agents/<Name>.agent.md` |
| Legacy skill-owned single work adapter | `skills/<skill>/SKILL.md` |
| Skill-as-adapter single work adapter | `skills/<skill>/adapters/<port>-adapter.md` |
| Skill-owned variant or work file | `skills/<skill>/adapters/<variant>.md` |
| Auto-N/A adapter | `skills/<skill>/adapters/<port>-auto-na-adapter.md` |
| Explicit-skip adapter | `skills/<skill>/adapters/<port>-explicit-skip-adapter.md` |

Lowercase Claude shells and slash commands are dispatchers, not adapters; they do not declare `provides:`.

### Per-port adapter table

New single-variant work adapters should prefer the skill-as-adapter path: declare `adapter-type: work`, name the file `skills/{skill}/adapters/{port}-adapter.md`, and rely on the default executor `agents/Senior-Engineer.agent.md` unless a slice explicitly names another `agents/*.agent.md` executor. Multi-variant work ports use selector-named adapter files plus `applies-when:` and `## When to use` guidance so the planner can choose the right variant.

| Port | Applies | Work declaration | Work predicate | Auto-N/A declaration | Explicit-skip declaration |
|---|---|---|---|---|---|
| `experience` | always | `agents/Experience-Owner.agent.md` | (single adapter) | `skills/customer-experience/adapters/experience-auto-na-adapter.md` — `changeset.complexity == 'trivial'` | `skills/customer-experience/adapters/experience-explicit-skip-adapter.md` |
| `design` | always | `agents/Solution-Designer.agent.md` | (single adapter) | `skills/design-exploration/adapters/design-auto-na-adapter.md` — `changeset.complexity == 'trivial'` | `skills/design-exploration/adapters/design-explicit-skip-adapter.md` |
| `plan` | always | `agents/Issue-Planner.agent.md` | (single adapter) | `skills/plan-authoring/adapters/plan-auto-na-adapter.md` — `changeset.complexity == 'trivial'` | `skills/plan-authoring/adapters/plan-explicit-skip-adapter.md` |
| `implement-code` | always | `agents/Code-Smith.agent.md` | `changeset.touchesSource()` | `skills/implementation-discipline/adapters/implement-code-auto-na-adapter.md` — `not changeset.touchesSource()` | `skills/implementation-discipline/adapters/implement-code-explicit-skip-adapter.md` |
| `implement-test` | always | `agents/Test-Writer.agent.md` | `changeset.touchesTestableCode()` | `skills/test-driven-development/adapters/implement-test-auto-na-adapter.md` — `not changeset.touchesTestableCode()` | `skills/test-driven-development/adapters/implement-test-explicit-skip-adapter.md` |
| `implement-refactor` | always | `agents/Refactor-Specialist.agent.md` for hub flow; `skills/refactoring-methodology/adapters/implement-refactor-adapter.md` for `/spine-run` | `changeset.touchedAreaHasRefactorableDebt()` | `skills/refactoring-methodology/adapters/implement-refactor-auto-na-adapter.md` — `not changeset.touchedAreaHasRefactorableDebt()` | `skills/refactoring-methodology/adapters/implement-refactor-explicit-skip-adapter.md` |
| `implement-docs` | always | `agents/Doc-Keeper.agent.md` | `changeset.changesBehaviorOrInterface()` | `skills/documentation-finalization/adapters/implement-docs-auto-na-adapter.md` — `not changeset.changesBehaviorOrInterface()` | `skills/documentation-finalization/adapters/implement-docs-explicit-skip-adapter.md` |
| `review` standard | always | `agents/Code-Review-Response.agent.md`; `skills/adversarial-review/adapters/standard.md` | `changeset.totalLines >= 200 and not scope.isReReview and not scope.isProxyGithub` | none — always applies | `skills/adversarial-review/adapters/review-explicit-skip-adapter.md` |
| `review` lite | always | `agents/Code-Review-Response.agent.md`; `skills/adversarial-review/adapters/lite.md` | `changeset.totalLines < 200 and not scope.isReReview and not scope.isProxyGithub` | none — always applies | `skills/adversarial-review/adapters/review-explicit-skip-adapter.md` |
| `review` judge-only | always | `agents/Code-Review-Response.agent.md`; `skills/adversarial-review/adapters/judge-only.md` | `scope.isReReview` | none — always applies | `skills/adversarial-review/adapters/review-explicit-skip-adapter.md` |
| `review` proxy-github | always | `agents/Code-Review-Response.agent.md`; `skills/adversarial-review/adapters/proxy-github.md` | `scope.isProxyGithub` | none — always applies | `skills/adversarial-review/adapters/review-explicit-skip-adapter.md` |
| `ce-gate-cli` | always | `skills/customer-experience/adapters/ce-gate-cli.md` | `changeset.touchesCliSurface()` | `skills/customer-experience/adapters/ce-gate-cli-auto-na-adapter.md` — `not changeset.touchesCliSurface()` | `skills/customer-experience/adapters/ce-gate-cli-explicit-skip-adapter.md` |
| `ce-gate-browser` | always | `skills/customer-experience/adapters/ce-gate-browser.md` | `changeset.touchesBrowserSurface()` | `skills/customer-experience/adapters/ce-gate-browser-auto-na-adapter.md` — `not changeset.touchesBrowserSurface()` | `skills/customer-experience/adapters/ce-gate-browser-explicit-skip-adapter.md` |
| `ce-gate-canvas` | always | `skills/customer-experience/adapters/ce-gate-canvas.md` | `changeset.touchesCanvasSurface()` | `skills/customer-experience/adapters/ce-gate-canvas-auto-na-adapter.md` — `not changeset.touchesCanvasSurface()` | `skills/customer-experience/adapters/ce-gate-canvas-explicit-skip-adapter.md` |
| `ce-gate-api` | always | `skills/customer-experience/adapters/ce-gate-api.md` | `changeset.touchesApiSurface()` | `skills/customer-experience/adapters/ce-gate-api-auto-na-adapter.md` — `not changeset.touchesApiSurface()` | `skills/customer-experience/adapters/ce-gate-api-explicit-skip-adapter.md` |
| `release-hygiene` | trigger-conditional | `skills/plugin-release-hygiene/SKILL.md` | `changeset.touchesPluginEntryPoint()` | none — N/A by trigger absence | `skills/plugin-release-hygiene/adapters/release-hygiene-explicit-skip-adapter.md` |
| `post-pr` | always | `skills/post-pr-review/SKILL.md` | (single adapter) | none — always applies | `skills/post-pr-review/adapters/post-pr-explicit-skip-adapter.md` |
| `post-fix-review` | trigger-conditional | `skills/adversarial-review/adapters/post-fix.md` | `review.sustainedCriticalOrHigh == true` | none — N/A by trigger absence | `skills/adversarial-review/adapters/post-fix-review-explicit-skip-adapter.md` |
| `process-review` | trigger-conditional | `agents/Process-Review.agent.md` | `ceGate.defectsFound > 0` | none — N/A by trigger absence | `skills/process-analysis/adapters/process-review-explicit-skip-adapter.md` |
| `process-retrospective` | deferred | `skills/process-retrospective/SKILL.md` (skeleton; trigger deferred to #348) | `never` (DSL deterministic-false; live predicate authored by #348) | none — deferred skeleton; no auto-N/A adapter | `skills/process-retrospective/adapters/process-retrospective-explicit-skip-adapter.md` |

### Selection (where judgment lives)

Each agent that owns a port is responsible for selection. When the agent runs:

1. If the active v2 frame slice includes `adapter:`, Spine-Runner treats the value as a repo-relative adapter path and invokes it only when that file exists and is one of the supported adapter surfaces.
2. If `adapter:` is absent, legacy and non-runner consumers may read the port file for predicate-based selection. Spine-Runner halts on an unresolvable adapter path rather than guessing a short ID or nearby file.
3. Evaluate each adapter's `applies-when` against the changeset.
4. Pick the matching adapter (port file declares precedence if multiple match: `default: review-standard`).
5. If no adapter matches, invoke the explicit-skip adapter with a justification.

The pre-PR hook independently verifies via the credit. Selection logic is never re-run by the hook — it just checks that *some* credit exists.

Review adapter selection is mutually exclusive: `judge-only` and `proxy-github` match their scope flags, while `standard` and `lite` both require those flags to be false.

### `applies-when` predicate language

Target enforcement evaluates the declarative DSL against:

- `git diff` against the merge target (file list, line counts, paths)
- Repo signals (file patterns, surface markers)
- Operator-supplied review routing flags for specialized review modes (`scope.isReReview`, `scope.isProxyGithub`) and explicit-skip justification

Examples:

```yaml
applies-when: changeset.touches('src/ui/**')
applies-when: changeset.totalLines < 200 and not scope.isReReview and not scope.isProxyGithub
applies-when: not changeset.touchesSource()
applies-when: changeset.changesBehaviorOrInterface()
```

The grammar is small and deterministic. Current validation is parse-only: it accepts comparisons, logical `AND`/`OR`/`NOT`, grouped expressions, dotted identifiers, bare boolean identifiers such as `scope.isReReview`, and function-call predicates with literal arguments such as `changeset.touches('docs/**')`. It rejects malformed syntax but does not validate field existence, function existence, or type consistency; those semantic checks are deferred to the evaluator work. The target hook evaluates valid predicates; the agent does not.

### Predicate schema appendix

This is the **Provisional DSL surface (v1)**: every identifier or function below is used by a live adapter predicate and is subject to revision in #429 once warn-only hook interpretation is in place. The current parser accepts the shapes; #429 owns runtime meaning.

#### Predicate-DSL-evaluable vs runtime-resolver-only (issue #441 Decision 4)

Two tiers of identifier exist:

- **Predicate-DSL-evaluable** — evaluated by the parser and the warn-only hook evaluator without external port state: all `changeset.*` functions, `scope.*` bare booleans, and numeric/string comparisons. These identifiers describe changeset shape or invocation context and can be evaluated at hook time from the PR changeset alone.
- **Runtime-resolver-only** — credit-reference identifiers (`review.*`, `ceGate.*`) that read finding-shape semantics from a completed credit. These are evaluated by the **runtime resolver** in `.github/scripts/lib/frame-predicate-core.ps1` (`Resolve-SustainedCriticalOrHigh`), not by the predicate-DSL evaluator in isolation. The DSL parser accepts the syntax; the resolver supplies the runtime value when a `JudgeScore` is present.

Express-lane carve-out (`express_lane`) lives entirely in the runtime resolver alongside `review.sustainedCriticalOrHigh`. It is a per-finding field evaluated at credit-resolution time — never a predicate-DSL token.

| Identifier or function | Current intended shape | Tier |
|---|---|---|
| `changeset.touches` | Function with a literal glob argument, e.g., `changeset.touches('docs/**')` | DSL |
| `changeset.touchesAny` | Function with a literal array argument, e.g., `changeset.touchesAny(['plugin.json', '.claude-plugin/plugin.json'])` (issue #441 Step 4a) | DSL |
| `changeset.touchesSource` | Function returning whether source files changed | DSL |
| `changeset.touchesTestableCode` | Function returning whether testable production code changed | DSL |
| `changeset.touchedAreaHasRefactorableDebt` | Function returning whether touched areas need refactor review | DSL |
| `changeset.changesBehaviorOrInterface` | Function returning whether behavior or interface docs changed | DSL |
| `changeset.touchesCliSurface` | Function returning whether CLI surface files changed | DSL |
| `changeset.touchesBrowserSurface` | Function returning whether browser UI surface files changed | DSL |
| `changeset.touchesCanvasSurface` | Function returning whether canvas surface files changed | DSL |
| `changeset.touchesApiSurface` | Function returning whether API surface files changed | DSL |
| `changeset.touchesPluginEntryPoint` | Function returning whether plugin entry-point or distributed plugin files changed | DSL |
| `changeset.totalLines` | Numeric identifier used in comparisons | DSL |
| `changeset.complexity` | String identifier; current predicates use `'trivial'` | DSL |
| `scope.isReReview` | Bare boolean identifier for judge-only reruns | DSL |
| `scope.isProxyGithub` | Bare boolean identifier for proxy-GitHub review intake | DSL |
| `review.sustainedCriticalOrHigh` | Boolean credit-reference identifier for post-fix-review trigger predicates. **Resolved** (issue #441 Steps 4c/4d) by `Resolve-SustainedCriticalOrHigh` in `frame-predicate-core.ps1`: true iff any finding has severity in {Critical, High} AND ruling = uphold AND express_lane != true. | Runtime |
| `express_lane` | Per-finding boolean field evaluated at credit-resolution time. Not a predicate-DSL token; evaluated by the runtime resolver alongside `review.sustainedCriticalOrHigh`. **Resolved** (issue #441 Step 4d) — a qualifying finding with `express_lane: true` is excluded from the sustained-critical-or-high count. | Runtime |
| `ceGate.defectsFound` | Numeric credit-reference identifier for process-review trigger predicates. **Resolved** (issue #443 Step 2) by `Resolve-CeGateDefectsFound` in `frame-predicate-core.ps1`: reads `CeGate.DefectsFound` from the changeset object; returns `$null` when unavailable (unknown/deferred-credit path). | Runtime |
| `never` | Bare boolean DSL identifier that always evaluates to `false`. Used as the `applies-when` predicate for deferred trigger-conditional ports (`process-retrospective`) to deterministically exclude the port from the coverage denominator until its live trigger ships. **Resolved** (issue #443 Step 1) in `Resolve-FVIdentifierAsBoolean` in `frame-predicate-core.ps1`. | DSL |

### Rejected alternative: all-in-adapters

The all-in-adapters shape would put every adapter, including single work adapters, under `skills/<skill>/adapters/`. The D1 hybrid reduces total file count by declaring agent-owned and skill-owned single adapters in their canonical files, but it does create high-density skills such as `customer-experience` and `adversarial-review`; the SKILL.md adapter pointer sections mitigate that density by listing each port and adapter path near the owning methodology.

---

## Credit Ledger Schema (evolves existing pipeline-metrics)

The audit revealed that the **`<!-- pipeline-metrics ... -->` YAML block already embedded in every recent PR body IS the de facto credit ledger.** It is in production at `metrics_version: 2`, written by Code-Conductor on PR creation, and machine-parseable today. The frame ledger is `metrics_version: 3` — a backwards-compatible extension that adds port-level structure on top of the existing finding-level fields.

The previously documented marker `<!-- code-review-complete-{PR} -->` was design-on-paper — it did **not** appear on real PRs. It is officially retired as of issue #441 Step 11. Enforcement anchors on `credits[]` in the pipeline-metrics block in the PR body.

Per-agent issue markers (`<!-- experience-owner-complete-{ID} -->`, `<!-- design-phase-complete-{ID} -->`, `<!-- plan-issue-{ID} -->`) **do** appear reliably on linked issues and remain valuable as **evidence pointers** referenced by credit entries. They are not replaced.

The sample credit `adapter:` values below preserve legacy credit-ledger vocabulary from the v3 design era. They are evidence labels, not executable Spine-Runner slice adapter values; executable v2 frame slices use repo-relative adapter paths.

Senior Engineer skill-as-adapter credits use the existing builder row shape. The Senior Engineer subagent, not Spine-Runner directly, emits the terminal credit row at completion; the repo-relative adapter path is captured in `adapter` and repeated in human-readable `evidence` so attribution points to the methodology file that drove the work.

```yaml
# Embedded in PR body as an HTML comment
<!-- pipeline-metrics
metrics_version: 3
frame_version: 1.0
pr: 123
generated_at: 2026-04-24T14:30:00Z

# NEW in v3: per-port credits (preserves all v2 finding-level fields below)
credits:
  - port: experience
    adapter: experience-owner-upstream
    status: passed                          # passed | failed | skipped | not-applicable | inconclusive
    evidence: gh-issue-comment://issue/456#issuecomment-789
    applied-by: Experience-Owner
    selector-reason: "complexity > trivial"
    timestamp: 2026-04-24T14:00:00Z

  - port: design
    adapter: design-auto-na-adapter
    status: not-applicable
    rule: "changeset.complexity == 'trivial'"
    evidence: changeset:diff-stat@HEAD
    applied-by: Code-Conductor
    timestamp: 2026-04-24T14:02:00Z

  - port: ce-gate-browser
    adapter: exercise-browser-scenarios
    status: inconclusive
    reason: "browser tools unavailable in this environment; runtime scenarios not exercised"
    applied-by: Experience-Owner
    timestamp: 2026-04-24T14:20:00Z

  - port: review
    adapter: review-standard
    status: passed
    evidence: pipeline-metrics#findings           # internal pointer to v2 fields below
    applied-by: Code-Review-Response
    selector-reason: "changeset 1735/-785, full prosecution depth"
    judge-score: 5-accepted/1-rejected/0-deferred
    integrity-check:
      expected-prosecution-passes: [1, 2, 3]
      observed-prosecution-passes: [1, 2, 3]
      passed: true
    timestamp: 2026-04-24T14:25:00Z

  - port: post-fix-review
    adapter: post-fix-review-trigger-absent
    status: not-applicable
    rule: "no Critical or High finding sustained in review credit"
    timestamp: 2026-04-24T14:26:00Z

  - port: release-hygiene
    adapter: plugin-release-hygiene
    status: passed
    evidence: changeset:plugin.json,marketplace.json,README.md
    applied-by: Code-Conductor
    version-bump: 2.3.0 -> 2.3.1
    timestamp: 2026-04-24T14:28:00Z

  - port: implement-refactor
    adapter: implement-refactor-explicit-skip-adapter
    status: skipped
    reason: "Touched files have outstanding refactor PR #119; avoid conflicting cleanup."
    applied-by: Code-Conductor
    timestamp: 2026-04-24T14:18:00Z

  # ... 17 entries total (13 always-applies + 3 trigger-conditional + 1 deferred decision port)

# v2 fields preserved unchanged below — readers of v2 see the legacy block; v3-aware readers consume credits[]
prosecution_findings: 6
defense_disproved: 1
judge_accepted: 5
judge_rejected: 1
judge_deferred: 0
ce_gate_result: passed
ce_gate_intent: partial
ce_gate_defects_found: 0
rework_cycles: 1
postfix_triggered: false
findings: [ ... per-finding ledger as today ... ]
-->
```

### Credit-author rule

**The adapter writes its own credit on completion.** No central writer. This matches today's marker pattern and the existing pipeline-metrics writer in Code-Conductor.

For the v2 → v3 migration: Code-Conductor's existing pipeline-metrics emitter is extended to write the `credits:` array alongside the v2 fields. Per-port adapters provide their credit entry via a small helper protocol; Conductor concatenates them into the final block. v2-only consumers continue to read the legacy fields without breaking.

### Terminal-step rule (closes partial-completion gap)

For multi-stage adapters, **only the terminal step writes the credit.**

Concrete examples:

- `review` credit is written by the **judge** (Code-Review-Response) after consuming both prosecution and defense ledgers. Prosecution and defense produce inputs only — neither writes a credit.
- `implement-test` credit is written when tests are committed and pass, not when Test-Writer is dispatched.
- `ce-gate-{surface}` credit is written when the evidence summary is captured, not when the surface run starts.
- `implement-docs` credit is written when the doc edit is committed, not when Doc-Keeper is invoked.

**Consequence**: partial states (e.g., a prosecution ledger with no judge ruling) exist as recoverable orphans but cannot satisfy the port. The gate stays closed until the terminal step completes. Recovery is well-lit (`/orchestra:review-judge` consumes existing ledgers).

### Input-integrity rule

Terminal-step adapters verify their inputs are complete before writing the credit. Example: judge verifies the prosecution ledger contains all expected prosecution pass IDs (`pass: 1`, `pass: 2`, `pass: 3` for standard) before writing a `passed` credit. If a prosecution pass is missing, judge writes a `failed` credit (or refuses to write) with the gap as evidence.

This closes the only failure mode the terminal-step rule alone doesn't address: an adapter that internally short-circuits its sub-stages.

**Audit confirmation**: PR #411's pipeline-metrics block contains an explicit warning that "*pass-level distribution was not durably persisted in-session*" with `pass_1/2/3_findings: n/a`. Today this ships unchallenged. The integrity-check rule would have flagged it (observed-prosecution-passes: empty; expected: [1,2,3] for standard) and the judge would have written `failed` instead of `passed`.

**Express-lane carve-out**: PR #338 used `express_lane` to fast-path 5 of 12 findings past full defense. The integrity check must accept express-lane findings as valid — the rule is "every expected pass block has *some* terminating outcome (full ruling OR express-lane ruling)," not "every finding has full defense." The `express_lane: true` field on a finding entry counts as the terminator.

---

## Pre-PR Hook Contract

> **Shipped status (sub-issue #429, branch `feature/issue-429-pre-pr-warn-hook`):** the warn-only slice has landed.
>
> - **Schema**: `metrics_version: 4` — frame credits sit on top of the inherited v3 base. See `frame/pipeline-metrics-v4-schema.md` for the additive fields.
> - **Orchestrator**: `.github/scripts/frame-credit-ledger.ps1 -Pr <N> [-Mode warn|enforce]`. Default `-Mode warn`; `enforce` is reserved for sub-issue #13 and is not active in this slice.
> - **Methodology skill**: `skills/frame-credit-ledger/SKILL.md`, referenced from `agents/Code-Conductor.agent.md` Step 4 as the post-`gh pr create` observation step.
> - **Status**: warn-only. The hook posts an idempotent `<!-- frame-credit-ledger-{PR} -->` comment listing gaps; it does **not** block PR creation. Blocking-mode activation is deferred to sub-issue #13.
> - **Three-state taxonomy** for port coverage in the rendered ledger: `Covered | Inconclusive | NotCovered` — bare-string canonical at the data layer, with emoji applied at format-time only.
> - **Auto-N/A semantics**: D7 logical-AND. A port is N/A iff *every* declared work-adapter for that port has an `applies-when` predicate that evaluates `false` against the changeset. If any work-adapter applies, the port is live and absence of a credit becomes a gap.
>
> The pseudocode below remains the design target; some semantics (notably blocking on `missing` / `failed`) describe the eventual enforce-mode behavior tracked in sub-issue #13. The shipped warn-only orchestrator surfaces the same conditions as ledger entries rather than as PR-create blocks.
>
> **Known limitation (sub-issue #13 will need more than a default-flag flip):** the original AC-8 / D6 promise framed sub-issue #13 as "change one parameter, not refactor the script." That promise is no longer fully truthful for two reasons surfaced during the warn-only slice:
>
> 1. **Budget-exceeded enforce policy is undefined.** When the 30s outer budget elapses, the orchestrator currently returns exit 0 *unconditionally* (warn-mode invariant takes precedence over enforcement when no decision could be made). Sub-issue #13 will need to pick an explicit policy: (a) keep the current warn-invariant precedence, (b) treat budget-exceeded as a hard fail in enforce mode, or (c) emit a separate "enforce-deferred" exit code. None of these are a flag flip.
> 2. **AdapterDiscoveryFailed → Inconclusive routing.** When all adapters for a port resolve to `'unknown'` and no credit is present, the orchestrator currently routes to `Inconclusive`, not `NotCovered`. Sub-issue #13 will need to decide whether enforce mode treats `Inconclusive` as a block (strictest), as a pass (most permissive), or as a third "operator-must-acknowledge" path.
>
> Both decisions touch the orchestrator's main flow, not just its default `-Mode` value. The audit-update for sub-issue #13 should rescope from "flip the flag" to "flip the flag + adopt explicit enforce-mode policies for the two ambiguity cases above."

```text
on `gh pr create` (or push to PR branch with auto-PR):

  1. Read frame/ports/*.yaml                  # canonical port list
  2. Find the PR's frame-credit-ledger comment
     (if missing → BLOCK with "no credit ledger present; run frame init")
  3. For each port in frame:
       evaluate applies-when of each adapter against the live changeset
       look up the credit entry for this port in the ledger:
         - missing entry            → BLOCK with "missing credit: <port>"
         - status: failed           → BLOCK with "<port> failed, see <evidence>"
         - status: passed           → OK
         - status: skipped          → OK (justification visible in PR review)
         - status: not-applicable   → OK (rule cited in entry)
  4. All ports satisfied → allow PR creation
```

The hook never reads agent prose. It reads ports + ledger. The hook is the only enforcement layer (declined dual-layer-with-self-check during design — pre-PR hook only).

### Failure-message contract

Every BLOCK message names:

- The missing/failed port
- What adapter would have filled it (so the operator knows what to run)
- The recovery command (e.g., `/orchestra:review-judge`)

Operators should never see a generic "frame check failed" — always actionable.

---

## Audit-Only Kickoff (Sub-Issue #1)

Cheapest path to evidence: extend the existing pipeline-metrics block to v3 with a `credits[]` array, back-derive credit arrays from existing markers + PR-body sections across recent PRs, report the gap rate per port. **No enforcement yet.**

### Deliverables

1. **`frame/ports/*.yaml`** — the 17 port files (13 always-applies, 3 trigger-conditional, 1 deferred decision port), declarative.
2. **`frame/pipeline-metrics-v3-schema.yaml`** — schema doc that extends `metrics_version: 2` with the `credits[]` array, status enum (`passed | failed | skipped | not-applicable | inconclusive`), and integrity-check fields. Backwards-compatible with v2 readers.
3. **`scripts/frame-back-derive.ps1`** — script that, given a PR number:
   - Reads PR body (existing v2 pipeline-metrics block), diff, linked issue markers, PR-body sections (Adversarial Review Scores, CE Gate, Validation Evidence, Process Gaps)
   - Constructs a synthetic v3 credit array using the back-derivation rules below (era-aware)
   - Optionally posts the synthesized v3 block as a draft comment for inspection
4. **`scripts/frame-audit-report.ps1`** — runs back-derivation across the last N merged PRs, emits a report:
   - Per-port: how often `passed`, `not-applicable`, `skipped`, `inconclusive`, **missing**
   - Per-PR: which ports were missing
   - Top-N most-frequently-missing ports → drives sub-issue priority
   - Era split: pre-thin/fat (before PR #356, 2026-04-17) vs post-thin/fat — to test the hypothesis that drift increased after the split

### Back-derivation rules (era-aware)

| Signal | Implies | Era |
|---|---|---|
| `<!-- experience-owner-complete-{ID} -->` on linked issue | `experience: passed` | both |
| `<!-- design-phase-complete-{ID} -->` on linked issue | `design: passed` | both |
| `<!-- plan-issue-{ID} -->` on linked issue | `plan: passed` | post-thin/fat only |
| Linked issue body has "Implementation Plan" / "Acceptance Criteria" section but no `plan-issue-{ID}` marker | `plan: passed` (era-fallback) | pre-thin/fat |
| PR body contains `## Adversarial Review Scores` table with judge-rulings count > 0 | `review: passed` (with score) | both — primary signal |
| PR body contains `<!-- pipeline-metrics ... -->` v2 block with `judge_accepted/rejected/deferred` populated | `review: passed` integrity-check pass | both |
| Same block has `pass_1/2/3_findings: n/a` with reconstruction warning | `review: passed` integrity-check **fail** — flag for review | post-thin/fat (#411 case) |
| PR body has `## CE Gate` with "passed", "skipped", or "not applicable" wording | `ce-gate-*` per surface (default to single ce-gate-cli credit until surface-tagging exists) | both |
| PR body CE Gate says "skipped" with environment reason | `ce-gate-*: inconclusive` (NOT skipped — distinguish per V2 status enum) | both |
| Diff touches `plugin.json`, `.claude-plugin/plugin.json`, `marketplace.json`, or version badge | `release-hygiene: passed` if version bumped, else `failed` | post-thin/fat (release-hygiene era) |
| `## Adversarial Review Scores` shows "Post-fix Review" row with prosecutor pts | `post-fix-review: passed` | both |
| PR body mentions "Process-Review: not triggered" or absent and `ce_gate_defects_found: 0` | `process-review: not-applicable` (trigger absent) | both |
| PR body contains `## Process Retrospective` section | `process-retrospective: not-applicable` with `DEFERRED(#348):` prefix — trigger is deferred; back-deriver infers N/A for all historical PRs | issue #443 deferred-skeleton decision |
| PR body has `## Validation Evidence` with passed Pester/lint/structural checks | adapter input-integrity for `implement-test`/`implement-code` | both |
| Diff touches `docs/**` only | `implement-code/test/refactor: not-applicable`, `implement-docs: passed` | both |
| No signal found and no auto-N/A rule matches | **missing** (the gap) | both |

The audit's value is in the **missing** column — it tells us empirically which ports actually drift, and the era split tells us whether thin/fat made it worse.

### Audit's expected output (sample)

```text
=== Frame Audit Report (last 30 merged PRs) ===

Era split:
  pre-thin/fat (15 PRs):  missing-rate 11% across 14 ports
  post-thin/fat (15 PRs): missing-rate 19% across 17 ports

Most-missing ports (post-thin/fat):
  1. release-hygiene             missing in 5/15 PRs
  2. process-retrospective       missing in 14/15 PRs (likely retire)
  3. ce-gate-{surface}-specific  missing or surface-unspecified in 12/15 PRs
  4. review (integrity-check)    pass-distribution undurable in 4/15 PRs
  5. experience                  missing in 2/15 PRs

Recommended sub-issue priority:
  1. release-hygiene port + adapter (high frequency, easy enforcement)
  2. review integrity-check (closes the durability gap directly)
  3. CE Gate surface tagging (currently single-credit; needs per-surface)
  4. Decision: process-retrospective port or retire?
```

### Out of scope for the audit

- The pre-PR hook
- Adapter declarations in skill frontmatter
- Frame validator
- Any blocking behavior

These come in subsequent sub-issues, prioritized by audit findings.

---

## Sub-Issue Roadmap (Tentative)

Order is intentional but flexible — actual priority will shift based on audit-report missing-rate per port. Sub-issues 1–4 are foundational and should land in order; 5+ are port reifications driven by audit data.

| # | Real issue | Sub-issue | Deliverable | Depends on |
|---|---|---|---|---|
| 1 | #426 | **Audit-only credit ledger from existing markers + pipeline-metrics v3 schema** | Schema doc, port files (17), back-deriver script, audit report. No enforcement. | — |
| 2 | #427 | Frame validator (lint/CI step) | Walks `frame/ports/*.yaml` and adapter frontmatter; fails CI when an adapter declares a non-existent port and when `applies-when` cannot parse. Missing adapters for existing ports are allowed until coverage enforcement ships. | row 1 |
| 3 | #428 | Adapter declarations in skill/agent frontmatter | All current skills/agents declare `provides: <port>` and `applies-when` predicates. Validator (row 2) passes. | rows 1, 2 |
| 4 | #429 | Pre-PR hook (warn-only mode) | Hook exists, reads PR body's pipeline-metrics v4 frame credits (additive on inherited v3 base), posts a comment listing missing/failed/inconclusive credits. **Does not block.** **(SHIPPED on `feature/issue-429-pre-pr-warn-hook`)** — orchestrator at `.github/scripts/frame-credit-ledger.ps1`; methodology at `skills/frame-credit-ledger/SKILL.md`; comment marker `<!-- frame-credit-ledger-{PR} -->`. | rows 1, 3 |
| 5 | #430 (closed; bundled into #441) | Reify `review` port end-to-end with input-integrity check | Code-Review-Response writes the v3 credit on judge completion; integrity check verifies pass-block durability (closes #411-style gap). | row 4 |
| 6 | #431 (closed) | Reify `release-hygiene` port | plugin-release-hygiene skill declares `provides: release-hygiene`; predicate detects entry-point and distributed plugin file changes. | row 3 |
| 7 | #432 (closed) | Reify CE Gate surface ports + `inconclusive` status path | `ce-gate-cli/browser/canvas/api` adapters with surface-touch predicates; CE Gate emits `inconclusive` when environment unable to exercise (not silently `skipped`). | row 3 |
| 8 | #433 (closed) | Reify `experience`, `design`, `plan` ports | Pipeline-entry agents emit credits with `applies-when` based on `changeset.complexity`. | row 3 |
| 9 | #434 (closed) | Reify `implement-*` ports | Specialist agents emit credits; Validation Evidence table consumed as input-integrity inputs. | row 3 |
| 10 | #435 (closed) | Reify `post-pr` and `post-fix-review` ports | Trigger-conditional logic for post-fix-review; explicit credit for post-pr cleanup. | row 5 |
| 11 | #436 (closed) | Decision: `process-retrospective` port or retire | Audit usage feeds the ADR-0004 D14 deferred-skeleton pattern until the practice is formalized as a port, folded into `post-pr`, or retired. | row 1 |
| 12 | #438 (closed) | Reify `process-review` port | Trigger-conditional on CE Gate defects. | row 7 |
| 13 | #439 | Pre-PR hook switches to **blocking mode** | After all 17 ports have adapters and audit shows acceptable credit-rate, hook upgrades from warn → block. **The actual rails turn on.** Per D17 (#442), blocking-mode activation requires ≥30-PR recalibration data, all post-spine. | all preceding |

Active aggregation issues: #441 (sub-A, closed 2026-05) covers rows 5, 6, and 10; **#442** (sub-B, active) covers rows 7, 8, and 9.

---

<!-- d14-reification-contract -->
## Sub-Issue Reification Contract (D14)

This section consolidates the named decisions governing port reification across all sub-issues. Decisions D7–D12 were first established during sub-A (#441) and the early sub-B (#442) design exploration; D13–D18 were named or reserved during sub-B. Together they form the canonical contract: any future port-reification sub-issue (sub-C: `process-review`, `process-retrospective`; sub-D+: any later ports) inherits this contract unless it explicitly overrides a named decision and records the override here.

**Decision-numbering policy**: decisions are numbered sequentially starting from D7 (the first sub-A builder-shape decision). Numbers D13–D16 were reserved during sub-B to maintain forward continuity; they will be filled as patterns emerge. Do not re-use or re-assign a reserved slot without retiring its placeholder entry.

### D7 — Builder shape

One `Build-{Port}CreditRow` function per port in `.github/scripts/lib/frame-credit-ledger-core.ps1`, mirroring the sub-A `Build-ReviewCreditRow` pattern. CE Gate is a single builder parameterised by `-Surface [ValidateSet('cli','browser','canvas','api')]`. Each builder:

- Accepts port-specific evidence inputs (not a generic bag).
- Returns an ordered hashtable conforming to the v4 `credits[]` schema (`port`, `status`, `evidence`; optionally `block_kind`, `mode`).
- Is unit-tested by a dedicated Pester contract in `Tests/{port}-credit-emission.Tests.ps1`.

Schema-conformance contract (`Tests/credit-row-schema-conformance.Tests.ps1`) iterates all `Build-*CreditRow` functions and validates their output against `frame/pipeline-metrics-v4-schema.md` to prevent drift across ports over time.

### D9 — Emission path and row disambiguation

Two distinct emission paths with structurally distinguishable row shapes:

| Row shape | Meaning |
|---|---|
| No `mode` field | Forward-emitted — adapter wrote the credit at its terminal step with concrete evidence |
| `mode.synthetic-backfill: {backfilled_at, original_pr_merged_at}` | Back-derived — the back-deriver inferred the credit from historical PR evidence; audit confidence is limited |
| `block_kind: environment\|tooling\|runtime\|orchestration` (CE Gate only) | Forward-emitted `inconclusive` — runtime environment prevented the surface from being exercised |

**Additive-merge rule**: when the PR's pipeline-metrics block already contains a `credits[]` array (e.g., a v4-era PR that ran sub-A review adapters before sub-B shipped), the back-deriver fills only the absent ports. Present ports are preserved as-is — no double-write, no overwrite, no `mode.synthetic-backfill` added to forward-emitted rows.

`block_kind: orchestration` covers the case where CE Gate orchestration crashed before a surface was evaluated; the missing-surface credits are emitted as `inconclusive` by the orchestration wrapper rather than silently absent.

### D10 — Selector locus (4 categories)

| Category | Ports | When credit is written | Who writes it |
|---|---|---|---|
| 1 — Agent-owned, post-PR | `implement-code`, `implement-test`, `implement-refactor`†, `implement-docs` | Specialist's terminal step, after PR creation | Specialist agent for hub flow; resolved work-adapter executor for `/spine-run`, directly into PR-body pipeline-metrics block |
| 2 — Agent-owned, pre-PR (deferred emission) | `experience`, `design`, `plan` | Stage A: agent posts `<!-- credit-input-{port}-{ID} -->` YAML comment alongside its completion marker. Stage B: Code-Conductor harvests at `gh pr create` time | Pipeline-entry agent (stage A); Code-Conductor (stage B) |
| 3 — Skill-only | `post-pr` | Post-merge cleanup phase | Code-Conductor, after reading `frame/ports/post-pr.yaml` and invoking the post-pr-review skill |
| 4 — CE Gate surface | `ce-gate-{cli,browser,canvas,api}` | Per-surface terminal step; missing-surface credits emitted by orchestration wrapper on crash | Experience-Owner / CE Gate orchestration |

† **`implement-refactor` — split declaration state (#639)**: Code-Conductor hub flow retains the legacy `agents/Refactor-Specialist.agent.md` work declaration. The `/spine-run` surface now discovers the skill-as-adapter work declaration at `skills/refactoring-methodology/adapters/implement-refactor-adapter.md`. Auto-N/A and explicit-skip predicate adapters remain unchanged; runtime `/spine-run` exercise for this port is deferred to #641.

### D11 — Adapter stub bodies

12 adapter stub files per port-reification sub-issue (`{port}-auto-na-adapter.md` and `{port}-explicit-skip-adapter.md`). Format: frontmatter declares `provides`, `adapter-type: predicate`, `suggested-next-step`, `applies-when`; body is one or two sentences describing the credit shape. Behavior lives in `Build-*CreditRow`, not in the adapter body.

### D12 — Predicate identifiers

New predicate identifiers for new semantics; shipped predicates left untouched. Introduced by sub-B:

| Identifier | Semantics | Status |
|---|---|---|
| `changeset.isPipelineEntryTrivial` | `totalLines < 50 AND changedFiles <= 3 AND not changeset.touchesSource()` — auto-N/A for `experience`/`design`/`plan` | New in sub-B |
| `changeset.touchesTestableCodeOrTests` | Matches `*.ps1` source files **or** test paths — distinct from shipped `touchesTestableCode` (which excludes tests) | New in sub-B |
| `changeset.touchedAreaHasDebt(threshold)` | File > 300 lines OR cyclomatic complexity > 10 in any touched function | New in sub-B |
| `changeset.touchesBehaviorOrInterfaceDocsExtended` | Matches `Documents/**`, `**/SKILL.md`, `**/*.agent.md`, `commands/**/*.md`, `README.md`, `CLAUDE.md` — distinct from shipped `changesBehaviorOrInterface` | New in sub-B |

### D13 — Plan port back-derivation inference

When back-deriving the `plan` port, the presence of a linked resolved issue confirms that the issue lifecycle ran, but the audit does not read issue-body markers or completion-marker state. The back-deriver therefore emits `status: inconclusive` with evidence citing the inference limitation. This is the conservative default for all pipeline-entry ports (`design`, `plan`) when marker-level confirmation is unavailable. Referenced in the audit table as "D12/D13 decisions in body."

### D14 — Deferred-trigger-conditional port pattern

When a trigger-conditional port's trigger predicate has not been designed yet (the triggering semantics are scoped to a future issue), the port is formalized with a **deferred-skeleton** rather than omitted or left as `tbd-decision-pending`. Three invariants hold:

1. **`applies-when: never`** — the DSL bare identifier `never` evaluates to deterministic `false` in `Resolve-FVIdentifierAsBoolean`. The port's adapter fires on no PR while deferred, producing no false credits.
2. **`Build-DeferredPortCreditRow`** — a dedicated builder in `frame-credit-ledger-core.ps1` emits `status: not-applicable` with evidence prefixed `DEFERRED(#NNN):`. This prefix is the migration-detection contract: when #NNN ships a live `Build-{Port}CreditRow`, the prefix regex `^DEFERRED\(#\d+\):` identifies rows to replace.
3. **Coverage denominator exclusion** — deferred rows carry `trigger-status: deferred`; the audit and coverage dashboard exclude them from the denominator until the port's `trigger-status` flips to `live`.

A 90-day tripwire in `frame-credit-ledger.ps1` warns (never blocks) when a deferred port has remained deferred longer than 90 days. The warn-only invariant ensures the tripwire cannot interfere with PR creation.

First applied: `process-retrospective` (issue #443); trigger predicate and live adapter deferred to #348.

### D15 — (Reserved for future reification decisions)

Reserved. Same policy as D14.

### D16 — (Reserved for future reification decisions)

Reserved. Same policy as D14.

### D17 — Blocking-mode activation precondition

Blocking-mode activation for sub-issue #13 requires ≥30-PR recalibration data, all post-spine. The first PR with spine semantics merging restarts the counter for #439. The warn-only hook must accumulate that dataset before the gate switches from `warn` to `enforce` mode. Sub-issue #13 owns the enforcement switch; this decision prevents premature enforcement before the credit-rate baseline is established.

### D18 — Skill-first methodology

Per-agent terminal-step methodology lives in `skills/frame-credit-emission/SKILL.md` — a single authoritative source covering forward-emission (post-PR specialists), deferred-emission (pre-PR pipeline-entry agents), and CE Gate per-surface orchestration. Agent bodies add only a one-line load pointer plus their role-specific identity bits (port name, terminal-step anchor, emission category from D10). Avoids 8-body drift. Sub-C agents follow the same pattern.

---

## Open Questions Resolved by Audit

| V1 question | V2 resolution |
|---|---|
| Does the 13-port set cover everything? | **No.** Audit added 4: `release-hygiene`, `post-fix-review`, and `process-review` as trigger-conditional ports, plus `process-retrospective` as a deferred/TBD decision port. Total = 17 ports. |
| Is back-derivation accurate for both eras? | **Era-aware fallbacks required.** Pre-thin/fat PRs lack `plan-issue-{ID}` markers; the back-deriver infers from PR-body sections instead. Documented in the rules table. |
| How to distinguish "port wasn't required at the time" from "port was missed"? | Era split in audit report: pre-thin/fat reports against 14 ports, post-thin/fat against 17. Trigger-conditional ports auto-N/A under their trigger absence rule across both. |
| Does the flat list still feel right? | **Yes.** Walking 4 PRs, no decomposition pressure emerged. Display grouping (`implement-*`, `ce-gate-*`) is sufficient. |
| Where does selector logic live for ports without an agent owner (e.g., `post-pr`)? | Code-Conductor owns selection for ports whose adapter is a skill (not an agent). The selector reads the port file, evaluates `applies-when`, calls the skill or its auto-N/A adapter. Same pattern; just different invoker. |

## Open Questions Still Live (Resolve During Sub-Issue Work)

- ~~The `<!-- code-review-complete-{PR} -->` marker is documented but absent from real PRs. Should we (a) retire the marker from documentation, (b) backfill it via a hook on PR creation, or (c) leave it as an alias for the v3 review credit?~~ **Resolved in issue #441 Step 11**: chose option (a) — marker retired from documentation and emission. Code-Conductor reads `credits[]` from the `<!-- pipeline-metrics -->` block directly; legacy fallback preserved for pre-Step-11 PRs.
- ~~`process-retrospective` was visible in only 1 of 4 audited PRs. Decide in sub-issue #11 whether to formalize as a port, fold into `post-pr`, or retire the practice.~~ **Resolved in issue #443**: formalized as a trigger-conditional port with the deferred-skeleton pattern (D14). Port file at `frame/ports/process-retrospective.yaml`; skill skeleton at `skills/process-retrospective/SKILL.md`. Trigger predicate and live adapter are deferred to #348. Decision rationale and rejected alternatives in [`Documents/Decisions/0004-process-retrospective-deferred-skeleton.md`](Documents/Decisions/0004-process-retrospective-deferred-skeleton.md).
- CE Gate surface tagging is currently single-credit (one `ce-gate` block per PR, not per surface). Decide in sub-issue #7 whether to require surface-tagged credits or accept the single-credit shape with a `surfaces: [cli, browser]` field.
- For PRs that ran `review` in *both* main and proxy-GitHub modes (PR #415), do we emit one `review` credit or two? Decide in sub-issue #5 — probably one credit with a `mode: main+proxy` field, evidence linking both.

---

## Decision Log

| # | Decision | Choice | Rationale | Status |
|---|---|---|---|---|
| F1 | Enforcement gate location | Pre-PR hook only | Strongest rails; agent prose stops being load-bearing for completion checks. | V1 |
| F2 | Credit shape | **Evolve existing pipeline-metrics block to v3** (extend, don't replace) | Audit confirmed pipeline-metrics block already exists and is in production at v2. The `<!-- code-review-complete-{PR} -->` marker was design-on-paper and absent from real PRs — officially retired in issue #441 Step 11. Anchor on what exists. | V1 → **V2 revised** → **V3 marker retired** |
| F3 | First cut scope | Audit-only across all ports as sub-issue #1 | Cheapest path to evidence; surfaces real gap rate before building enforcement. | V1 |
| F4 | Adapter declaration | Skill/agent frontmatter declares `provides`, central manifest is truth | Robustness + low ceremony; validator catches drift. | V1 |
| F5 | Port shape | Flat ports, no sub-ports | Sub-port grouping added bookkeeping without structural meaning. Display can prefix-cluster. Confirmed by audit — no decomposition pressure emerged across 4 PRs. | V1 |
| F6 | Credit author | Adapter writes its own credit on completion | Matches today's marker pattern; avoids new bottleneck. Conductor remains the aggregator (writes the v3 block) but each adapter contributes its credit entry. | V1 |
| F7 | `applies-when` evaluator | Declarative DSL evaluated by the hook | Auditable; agent can't fudge applicability. | V1 |
| F8 | Selector locus | In each agent's prose, reading its own port file. Code-Conductor owns selection for skill-only ports (no agent owner). | Lightweight; no new component; hook independently verifies via credit. | V1 (clarified V2) |
| F9 | Port granularity principle | One port per customer-meaningful question about the PR | Internal stages of an adapter (prosecute/defend/judge) aren't separate ports. | V1 |
| F10 | All-or-nothing semantics | Terminal-step credit + input-integrity check | Partial states recoverable but not credit-writable; gate enforces at terminal point. **Audit confirmed need**: PR #411 shipped with `pass_1/2/3_findings: n/a` and an explicit "not durably persisted" warning that today goes unchallenged. | V1 (audit-validated V2) |
| F11 | Port applicability | Every port always applies; auto-N/A is an adapter, not a port-level skip | One mechanism, not two; no silent gaps; uniform audit trail. | V1 |
| F12 | **Trigger-conditional ports** | Three ports (`release-hygiene`, `post-fix-review`, `process-review`) activate only when a triggering signal appears in the changeset or another port's credit. Trigger-absent still emits an explicit credit. `process-retrospective` remains deferred/TBD and is not trigger-conditional. | Audit revealed `release-hygiene`, `post-fix-review` (in #286), and `process-review` (mentioned in #286, #411) have distinct triggers and scopes; folding them into other ports loses the conditional structure. | **V2 new** |
| F13 | **Credit status enum** | `passed` \| `failed` \| `skipped` \| `not-applicable` \| `inconclusive` | Audit revealed CE Gate "skipped — environment couldn't exercise" is neither a true skip nor truly N/A. Add `inconclusive` for environment/tooling-blocked states. | **V2 new** |
| F14 | **Auto-N/A predicate refinement** | Drop `scope.isHotfix` from `experience`/`design`/`plan`; use only `changeset.complexity == 'trivial'` | Audit showed PR #415 (a bug fix) ran all three with full marker chain. The hotfix predicate would have wrongly auto-N/A'd. | **V2 new** |
| F15 | **Release-hygiene as a port** | Add `release-hygiene` as trigger-conditional on plugin entry-point and distributed plugin file changes | Every recent PR shows version bumps with no enforcement; visible drift surface. | **V2 new** |
| F16 | **Express-lane carve-out in integrity check** | Integrity check accepts `express_lane: true` findings as valid terminators | PR #338 used express_lane on 5/12 findings; full-defense-required rule would have falsely flagged. | **V2 new** |
| F17 | **Pipeline-metrics versioning** | v2 → v3 is additive (preserve all v2 fields, add `credits[]` + `frame_version`). v2-only readers continue to work. | Backwards-compat is mandatory; existing tooling consumes v2 metrics today. | **V2 new** |

---

## Audit Evidence (4-PR Walkthrough)

PRs walked: **#411** (Phase 3 Code-Conductor, post-thin/fat), **#415** (inline-dispatch fix, post-thin/fat), **#286** (Fix Effectiveness, pre-thin/fat), **#338** (validated step commits, pre-thin/fat). Inflection point: PR #356 (issue #344, merged 2026-04-17) extracted thin-agents/fat-skills.

### Per-PR credit derivation (back-derived against V2 17-port set)

#### PR #411 — Phase 3 Code-Conductor (post-thin/fat, +1735/-785, 34 files)

| Port | Status | Evidence |
|---|---|---|
| `experience` | ✅ passed | `<!-- experience-owner-complete-403 -->` on issue #403 |
| `design` | ✅ passed | `<!-- design-phase-complete-403 -->` |
| `plan` | ✅ passed | `<!-- plan-issue-403 -->` |
| `implement-code/test/refactor/docs` | ✅ all 4 passed | 32 source/skill files, 7 new Pester contracts (29/29), composite extractions, README+CLAUDE+design doc |
| `review` | ⚠️ passed-with-integrity-fail | Adversarial scores 21/5; pipeline-metrics v2 block present BUT `pass_1/2/3_findings: n/a` with explicit "not durably persisted" warning. Today ships unchallenged. |
| `ce-gate-{cli,browser,canvas,api}` | ⏭️ all 4 N/A | "no exercisable customer surface" (meta-CE ran on orchestration surface, but not in surface enum) |
| `release-hygiene` | ✅ passed | Version bump 2.3.x → 2.3.1 across 4 manifest files + README badge |
| `post-pr` | ✅ passed | Version + docs symmetric |
| `post-fix-review` | ⏭️ trigger-absent | No Critical/High |
| `process-review` | ⏭️ trigger-absent | "not triggered; no sustained CE defect" |
| `process-retrospective` | ❌ missing | No Step 11 section |

#### PR #415 — Inline-dispatch fix (post-thin/fat, +382/-8, 12 files)

| Port | Status | Evidence |
|---|---|---|
| `experience` / `design` / `plan` | ✅ all passed | All three markers present on issue #412 — **disproves V1's `scope.isHotfix` auto-N/A predicate** |
| `implement-code/test/docs` | ✅ passed | 12 files, new Pester contract, session-hooks.md updated |
| `implement-refactor` | ⏭️ N/A | Surgical fix |
| `review` | ✅ passed (dual-mode) | Main: 0/0/0 (zero findings) + **proxy-GitHub intake** by owner: 3 accepted / 8 rejected. Two review modes; pipeline-metrics didn't capture proxy. |
| `ce-gate-*` | ⚠️ **inconclusive** | "*CE Gate skipped — runtime cross-surface manual scenarios were not exercised in this environment*" — today silent skip; V2 distinguishes as `inconclusive` |
| `release-hygiene` | ✅ passed | 2.3.4 bump |
| `post-pr` | ✅ passed | |
| `post-fix-review` / `process-review` | ⏭️ trigger-absent | |
| `process-retrospective` | ⏭️ deferred/TBD | No Step 11 section |

#### PR #286 — Fix Effectiveness (pre-thin/fat, +2367/-115, 3 files)

| Port | Status | Evidence |
|---|---|---|
| `experience` | ✅ passed | `<!-- experience-owner-complete-264 -->` |
| `design` | ✅ passed | `<!-- design-phase-complete-264 -->` |
| `plan` | ❓ inferred-passed | **No `plan-issue-264` marker** (era-mismatch); inferred from PR-body "Key design decisions" section. Triggers era-aware fallback rule. |
| `implement-code/test/docs` | ✅ passed | 1 src file, 34 new tests, design doc |
| `implement-refactor` | ⏭️ N/A | Greenfield |
| `review` | ✅ passed | 7 rulings, full pipeline-metrics with per-finding ledger (better than #411 — pre-thin/fat era persisted full pass distribution) |
| `ce-gate-*` | ✅ passed (single-credit, no surface tag) | S1–S4 scenarios passed, intent: strong |
| `release-hygiene` | ⏭️ N/A (era) | Pre-plugin-release |
| `post-fix-review` | ✅ passed | Triggered by MF1 Critical, 0 findings clean — first concrete `post-fix-review` credit observed |
| `process-review` | ⏭️ trigger-absent | "no systemic gap found" |
| `process-retrospective` | ✅ passed | Explicit Step 11 section with slowdowns + workflow-guardrail improvement (the only PR with this) |

#### PR #338 — Validated step commits (pre-thin/fat, +243/-6, 11 files)

| Port | Status | Evidence |
|---|---|---|
| `experience` | ❌ **MISSING** | No `<!-- experience-owner-complete-336 -->` on issue #336 — **first real gap caught by audit** |
| `design` | ✅ passed | `<!-- design-phase-complete-336 -->` |
| `plan` | ❓ inferred-passed | No marker (era); D12/D13 decisions in body |
| `implement-code/test/docs` | ✅ passed | 11 files, Pester 385/0, design doc + 3 example dirs |
| `implement-refactor` | ⏭️ N/A | New feature |
| `review` | ✅ passed | 7 rulings; `express_lane_count: 5` (5/12 findings shortcut) — **drives F16 carve-out** |
| `ce-gate-*` | ⏭️ N/A | "agent orchestration definition change with no independently exercisable customer surface" — clean justified N/A, exact V1 model |
| `release-hygiene` | ⏭️ N/A (era) | |
| `post-fix-review` / `process-review` | ⏭️ trigger-absent | |
| `process-retrospective` | ⏭️ deferred/TBD | No Step 11 section |

### Cross-PR aggregate (4-PR sample)

| Port | passed | N/A | inconclusive | missing |
|---|---|---|---|---|
| `experience` | 3 | 0 | 0 | **1** (PR #338) |
| `design` | 4 | 0 | 0 | 0 |
| `plan` | 2 | 0 | 0 | 2 (era-fallback inferred-passed) |
| `implement-code/test/docs` | 4 each | 0 | 0 | 0 |
| `implement-refactor` | 1 | 3 | 0 | 0 |
| `review` | 4 (1 with integrity-fail) | 0 | 0 | 0 |
| `ce-gate-*` (any) | 2 | 1 | **1** | 0 |
| `release-hygiene` | 2 | 2 (era) | 0 | 0 |
| `post-pr` | 4 | 0 | 0 | 0 (inferred) |
| `post-fix-review` | 1 | 3 | 0 | 0 |
| `process-review` | 0 | 4 | 0 | 0 |
| `process-retrospective` | 1 | 0 | 0 | **3** |

Sample is too small to draw rates from. The audit-only sub-issue runs against the last 30+ PRs to produce statistically-meaningful gap rates.
