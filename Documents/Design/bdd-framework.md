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
### SN — <title> (Functional) [auto]
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
   - **Abort** — write abort marker and stop

**Abort marker** (written to PR body when chosen):

```text
❌ CE Gate aborted — pre-flight: {N} of {M} scenarios uncovered after {cycles} recovery cycles
```

**Recovery budget**: 2 cycles maximum, independent of CE Track 1 fix-revalidate budget.

---

## PR Body Coverage Table

When BDD is enabled, Code-Conductor includes a CE Gate coverage table in the PR body:

| Scenario | Type | Class | Status |
|----------|------|-------|--------|
| S1 — \<title\> | Functional | [auto] | ✅ Exercised |
| S2 — \<title\> | Intent | [manual] | ✅ Exercised |
| S3 — \<title\> | Functional | [auto] | ⚠️ Waived — \<reason\> |

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

Repos **without** `## BDD Framework` head keep the existing natural-language CE Gate workflow — no structural changes to Evidence Summary format or CE prosecution perspectives.

See [customer-experience-gate.md](customer-experience-gate.md) for the full CE Gate protocol (delegation model, two-track defect response, fix-revalidate budget).

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

### Phase 2 — Deferred (Separate Issue)

Gherkin conversion and framework runner integration:

- Conversion of S-ID scenarios to `.feature` files using consumer-stack-native BDD framework (Cucumber, Behave, SpecFlow, etc.)
- Consumer `copilot-instructions.md` config section for framework mapping
- Automated test case generation from G/W/T scenarios
- CI integration for feature file execution

**Deferral rationale**: Phase 2 requires consumer-facing tooling choices (framework selection, runner configuration, CI wiring) that vary significantly by tech stack and are too risky to bundle with Phase 1's foundational traceability work. Phase 1 establishes the ID and authoring contract that Phase 2 will build on.

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
