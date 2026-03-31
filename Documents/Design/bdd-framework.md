# Design: BDD Framework Integration

## Summary

The BDD Framework adds structured Given/When/Then scenario authoring with numbered ID traceability across the full agent pipeline. Experience-Owner authors G/W/T scenarios in the issue body before implementation; Scenario IDs (S1, S2…) flow through Issue-Planner classification, Code-Conductor CE pre-flight, the PR coverage table, and Code-Critic CE prosecution. A hard coverage-gap gate in Code-Conductor catches unexercised scenarios before a PR is created.

Consumer repos opt in via a `## BDD Framework` heading in `copilot-instructions.md`. Repos without that heading keep the existing natural-language workflow unchanged.

**CE Gate integration**: see [Documents/Design/customer-experience-gate.md](customer-experience-gate.md).

---

## Design Decisions

| # | Decision | Choice | Rationale |
|---|----------|--------|-----------|
| D1 | Scenario authoring location and enforcement model | G/W/T scenarios written to the issue body under `## Scenarios` (H2) **before** implementation; phased enforcement | Issue body is the single authoritative artifact that all pipeline agents can read; H2 boundary makes extraction unambiguous; Phase 1 establishes the pattern, Phase 2 adds framework-specific automation |
| D2 | Scenario ID convention | S-integer IDs (S1, S2, S3…); immutable after plan approval; no ID reuse; scenario splits create new sequential IDs | Immutability prevents traceability breaks mid-pipeline; sequential IDs are human-readable and grep-stable; deferred Gherkin conversion can map these IDs to feature file tags |
| D3 | Scenario extraction mechanism | Code-Conductor uses `### S\d+` grep scoped within `## Scenarios` to next H2 boundary to enumerate IDs before CE pre-flight | Grep-based extraction is stateless, requires no tooling beyond what agents already have, and is trivially auditable |
| D4 | Coverage gap detection | Hard pre-flight gate in Code-Conductor (`vscode/askQuestions`): Re-exercise / Waive / Abort; max 2 recovery cycles; abort marker written to PR body | Hard gate prevents silent misses; `vscode/askQuestions` is the established recovery mechanism used by CE Track 1; 2-cycle budget matches the existing CE fix-revalidate loop budget (D2 in customer-experience-gate.md) |
| D5 | Opt-in detection | Presence of `## BDD Framework` heading in consumer repo's `copilot-instructions.md`; template ships BDD-disabled | Heading-based detection requires no tooling config and is readable and grep-stable; template stays BDD-disabled so downstream repos that are not code repos are not forced into G/W/T workflow |
| D6 | Phase 2 activation mechanism | Both `## BDD Framework` heading AND `bdd: {framework}` line required; `bdd: true` / unrecognized → warning + Phase 1 fallback | Requiring both conditions prevents accidental activation; sentinel `bdd: true` had a documented Phase 2 placeholder role in Phase 1 that must be preserved as a graceful upgrade path rather than silent failure |
| D7 | Supported framework mapping | Four entries: `cucumber.js`, `behave`, `jest-cucumber`, `cucumber` (JVM); each maps to a runner command, version check, and default feature directory | Explicit mapping table allows exact, testable dispatch commands and predictable output locations; unrecognized values fall back to Phase 1 to limit blast radius of misconfiguration |
| D8 | Unified evidence record schema | 5-field record: `scenario_id`, `source` (`runner \| eo \| runner+eo`), `result` (`pass \| fail \| conflict`), `detail`, `raw_exit_code` (runner only) | Unified schema flows from runner → merge → EO evidence → Code-Critic without format negotiation; `source` field enables per-source evaluation rules in prosecution |
| D9 | Runner dispatch and EO conditional delegation | Runner dispatches per scenario using `@S{N}` tag filter; EO receives only scenarios CC delegates (Phase 1: all; Phase 2: conditional on runner pass/fail); conflict = Concern, not Issue | Conditional delegation avoids redundant EO exercise of runner-verified [auto] scenarios; classifying conflict as Concern prevents false automation failures when runner and EO disagree |

---

## Scenario Authoring (Experience-Owner)

When BDD is enabled, Experience-Owner writes scenarios **before** handing off to Issue-Planner:

```text
### S1 — <title> (Functional)

**Given** <precondition in customer language>
**When** <user action>
**Then** <observable outcome>
```

- `(Functional)` or `(Intent)` type tag is set by Experience-Owner
- Scenarios go under `## Scenarios` in the issue body
- IDs are sequential from S1; no gaps, no reuse after plan approval
- Scenario content stays in customer language — no implementation details

---

## Scenario ID Lifecycle

```text
Experience-Owner → ## Scenarios in issue body  (S1, S2…)
Issue-Planner    → CE GATE plan step            (S-IDs + [auto]/[manual] classification)
Code-Conductor   → CE pre-flight grep           (### S\d+ within ## Scenarios .. next H2)
Experience-Owner → evidence summary             (S-IDs confirmed exercised)
Code-Conductor   → PR body coverage table       (Type, Class, Status per S-ID)
Code-Critic      → CE prosecution               (evaluates each S-ID individually)
```

**ID rules**:

- Immutable after plan approval — no renumbering, no gaps
- Scenario splits create new sequential IDs (e.g., S4 → S4 + S5)
- Retired scenarios are marked `[REMOVED]`, not deleted (preserves ID space)

---

## Classification Rubric (Issue-Planner)

Issue-Planner classifies each scenario as `[auto]` or `[manual]` in the CE GATE plan step:

| Condition | Classification |
|-----------|---------------|
| Functional type + observable, deterministic outcome | `[auto]` |
| Intent type + subjective or aesthetic outcome | `[manual]` |
| Functional type, but requires live external dependency | `[manual]` (override) |
| Intent type, but outcome is binary and verifiable | `[auto]` (override) |

Format in plan:

```text
S1: {description} [auto/manual]
```

---

## Code-Conductor CE Pre-flight Gate

Step 4 of Code-Conductor runs the BDD pre-flight gate when BDD is enabled:

1. Grep `### S\d+` within `## Scenarios` to the next H2 boundary — produce authoritative S-ID list
2. Check Evidence Summary for each S-ID label
3. If all IDs present → pass, continue to PR creation
4. If any IDs missing → present `vscode/askQuestions`:
   - **Re-exercise** — ask Experience-Owner to exercise the missing scenario(s) and update evidence
   - **Waive** — record a documented waiver in the PR body with justification
   - **Abort** — stop the recovery cycle; emit `❌ CE Gate aborted — pre-flight: {N} of {M} scenarios uncovered` in the PR body; PR creation continues with the abort marker and documented reason

**Abort marker** (written to PR body when chosen):

```text
❌ CE Gate aborted — pre-flight: {N} of {M} scenarios uncovered after {cycles} recovery cycles
```

**Recovery budget**: 2 cycles maximum, independent of CE Track 1 fix-revalidate budget.

---

## PR Body Coverage Table

When BDD is enabled, Code-Conductor includes a CE Gate coverage table in the PR body:

| ID  | Type       | Class    | Result                  | Evidence             |
| --- | ---------- | -------- | ----------------------- | -------------------- |
| S1  | Functional | [auto]   | ✅ Passed               | {brief description}  |
| S2  | Intent     | [manual] | ✅ Passed               | {brief description}  |
| S3  | Functional | [auto]   | ⚠️ Waived — {reason}   | {link to waiver}     |

---

## Code-Critic CE Prosecution

When S-IDs are present in CE evidence, Code-Critic evaluates each scenario individually:

- Checks that each `[auto]` scenario has a tool-verified outcome (screenshot, response, stdout)
- Checks that each `[manual]` scenario has a human-readable observation note
- Flags scenarios where evidence is generic or does not correspond to the scenario's `Then` clause
- Reports per-scenario verdict in prosecution findings

---

## CE Gate Integration

BDD scenarios flow into the CE Gate as follows:

1. Experience-Owner authors G/W/T scenarios (EO phase)
2. Issue-Planner adds `[auto]`/`[manual]` classification to CE GATE plan step
3. Code-Conductor CE pre-flight checks that each S-ID was exercised (Step 4)
4. Experience-Owner exercises each scenario and records S-ID labels in Evidence Summary
5. Code-Critic CE prosecution evaluates each S-ID individually in the adversarial review

Repos **without** `## BDD Framework` **heading** keep the existing natural-language CE Gate workflow — no structural changes to Evidence Summary format or CE prosecution perspectives.

See [customer-experience-gate.md](customer-experience-gate.md) for the full CE Gate protocol (delegation model, two-track defect response, fix-revalidate budget).

---

## Phase 2: Gherkin Conversion & Runner Dispatch

### Activation

Phase 2 requires **both** conditions:

1. `## BDD Framework` heading present in consumer's `copilot-instructions.md`
2. `bdd: {framework}` line under that heading with a recognized framework value

| Condition | Behavior |
|-----------|----------|
| Heading present + `bdd: {framework}` recognized | Phase 2 active |
| Heading present, no `bdd:` line | Phase 1 (existing behavior, unchanged) |
| Heading present + `bdd: true` | Warning emitted; Phase 1 fallback |
| Heading present + `bdd: {unknown}` | Warning emitted; Phase 1 fallback |

### Framework Mapping

| Framework | `bdd:` value | Feature directory | Runner command | Version check |
|-----------|-------------|-------------------|----------------| --------------|
| cucumber.js | `cucumber.js` | `features/` | `npx cucumber-js --tags @S{N}` | `npx cucumber-js --version` |
| behave | `behave` | `features/` | `behave --tags @S{N}` | `behave --version` |
| jest-cucumber | `jest-cucumber` | `features/` | `npx jest --testPathPattern features` | `npx jest --version` |
| cucumber (JVM) | `cucumber` | `src/test/resources/features/` | `./gradlew test -Dcucumber.filter.tags=@S{N}` | `./gradlew --version` |

### Gherkin Generation (Test-Writer)

- Generates one `.feature` file per issue (idempotent — regenerated each pipeline run)
- Includes `[auto]` scenarios only; `[manual]` scenarios are excluded
- Each scenario tagged with `@S{N}` for per-scenario runner dispatch filtering
- Output location: framework-default directory from mapping table
- Consumer maintains assertion step definitions; Test-Writer generates scenario outlines only

### Runner Dispatch (Code-Conductor CE Gate, Step 3)

1. **Pre-check**: run version check command from mapping table; fail → warning + Phase 1 fallback (all scenarios delegated to EO)
2. **Per-scenario dispatch**: run runner with `@S{N}` tag filter for each `[auto]` scenario
3. **Evidence capture**: record 5-field unified evidence record per scenario (`scenario_id`, `source`, `result`, `detail`, `raw_exit_code`)
4. **Conditional EO delegation**: all `[auto]` passed → EO receives `[manual]` only; any `[auto]` failed → add failed scenarios; pre-check failed → all scenarios
5. **Evidence merge**: after EO delegation returns, merge EO evidence for all delegated scenarios; runner primary for `[auto]`; EO primary for `[manual]`; divergence → `source: runner+eo`, `result: conflict`

### Unified Evidence Record Schema

| Field | Type | Notes |
|-------|------|-------|
| `scenario_id` | string | e.g., `S1` |
| `source` | `runner \| eo \| runner+eo` | Origin of evidence |
| `result` | `pass \| fail \| conflict` | Outcome |
| `detail` | string | Summary or first stderr line |
| `raw_exit_code` | int | Runner source only |

### Code-Critic Runner Evidence Evaluation

When the unified evidence record contains a `source` field, Code-Critic applies source-specific evaluation semantics:

| Source | Result | Code-Critic treatment |
|--------|--------|-----------------------|
| `runner` | `pass` | Strong Functional evidence — focus scrutiny on Intent and Error States |
| `runner` | `fail` | Concern under Functional lens; cite `detail` and `raw_exit_code` |
| `runner+eo` | `conflict` | Concern (not Issue); include both records; request clarification |
| `eo` | any | Phase 1 per-scenario evaluation unchanged |

### PR Body Coverage Table (Phase 2 extension)

```text
| ID  | Type       | Class    | Result    | Evidence            | Source |
| --- | ---------- | -------- | --------- | ------------------- | ------ |
| S1  | Functional | [auto]   | ✅ Passed | exit 0, 1 assertion | Runner |
| S2  | Intent     | [manual] | ✅ Passed | {observation note}  | EO     |
```

---

## Opt-In Detection

| State | Detection | Behavior |
|-------|-----------|----------|
| BDD enabled | `## BDD Framework` heading present in `copilot-instructions.md` | G/W/T authoring required; S-IDs mandatory; pre-flight gate active |
| BDD disabled | Heading absent | Natural-language CE scenarios; no S-IDs; pre-flight gate skipped |

The template repo (`Copilot-Orchestra`) ships BDD-**disabled**. Example repos (`examples/*/copilot-instructions.md`) ship with a `## BDD Framework` section and a commented note showing how to remove it.

---

## Phased Rollout

### Phase 1 — Delivered (Issue #223)

Structured authoring and traceability infrastructure:

- G/W/T scenario format in the issue body with S-integer IDs
- Experience-Owner authoring section with ID and type-tag conventions
- Issue-Planner classification rubric (`[auto]`/`[manual]`)
- Code-Conductor CE pre-flight gate (grep extraction, gap detection, 3-option recovery)
- Code-Critic CE prosecution evaluates S-IDs individually
- PR body coverage table (Type, Class, Status per scenario)
- `bdd-scenarios` skill with authoring patterns and ID lifecycle guidance
- Consumer opt-in via `## BDD Framework` heading; template ships BDD-disabled

### Phase 2 — Delivered (Issue #227)

Gherkin conversion and framework runner integration:

- `bdd: {framework}` key in consumer `copilot-instructions.md` under `## BDD Framework` heading activates Phase 2
- Test-Writer generates a single `.feature` file per issue with `@S{N}` tags for each `[auto]` scenario
- Code-Conductor CE Gate runner dispatch: pre-check → per-scenario dispatch → evidence capture → conditional EO delegation → evidence merge
- Code-Critic runner evidence evaluation keyed on `source` field in unified evidence record
- Unified 5-field evidence record schema flows runner output through the full CE Gate pipeline
- Conditional EO delegation: EO receives `[manual]` only when all `[auto]` runners passed; all scenarios when pre-check failed; mixed list when some `[auto]` runners failed
- PR body coverage table extended with `Source` column (`Runner` / `EO`)

---

## Files Changed (Phase 1)

| File | Change |
|------|--------|
| `.github/skills/bdd-scenarios/SKILL.md` | NEW — G/W/T authoring patterns, classification rubric, ID lifecycle, extraction format |
| `.github/agents/Experience-Owner.agent.md` | G/W/T scenario authoring section with S-ID and type-tag conventions |
| `.github/agents/Issue-Planner.agent.md` | BDD classification rubric; CE GATE step format with S-IDs |
| `.github/agents/Code-Conductor.agent.md` | Step 4 BDD pre-flight gate (extraction, gap detection, 3-option recovery, abort marker) |
| `.github/agents/Code-Critic.agent.md` | CE prosecution mode evaluates S-IDs individually when present in evidence |
| `examples/*/copilot-instructions.md` (3 files) | Ship BDD-enabled with a commented disable note |
| `.github/copilot-instructions.md` | Updated skill count; BDD opt-in documentation |
| `CUSTOMIZATION.md` | BDD configuration guidance |

## Files Changed (Phase 2)

| File | Change |
|------|--------|
| `.github/skills/bdd-scenarios/SKILL.md` | Phase 2 section added: framework mapping table, Gherkin conversion rules, runner dispatch protocol, unified evidence schema, CE prosecution guidance |
| `.github/agents/Test-Writer.agent.md` | `## BDD Gherkin Generation (Phase 2)` section: activation, [auto]-only generation, @S{N} tags, skill reference, warning behavior |
| `.github/agents/Code-Conductor.agent.md` | CE Gate runner dispatch step (step 3); EO conditional delegation note; Source column in PR coverage table |
| `.github/agents/Experience-Owner.agent.md` | Phase 2 conditional delegation note in Downstream Phase section |
| `.github/agents/Code-Critic.agent.md` | Runner evidence evaluation block keyed on `source` field |
| `.github/agents/Issue-Planner.agent.md` | Phase 2 note below rubric table connecting [auto] → runner-executable |
| `examples/nodejs-typescript/copilot-instructions.md` | `bdd: cucumber.js` line added; Phase 2 comment replacing Phase 1 placeholder |
| `examples/python/copilot-instructions.md` | `bdd: behave` line added; Phase 2 comment |
| `examples/spring-boot-microservice/copilot-instructions.md` | `bdd: cucumber` line added; Phase 2 comment |
| `.github/copilot-instructions.md` | BDD description expanded to include Phase 2 capabilities |
| `.github/scripts/Tests/bdd-scenario-contract.Tests.ps1` | 4 new Phase 2 Describe blocks (16 It blocks) |
