---
name: bdd-scenarios
description: "Structured Given/When/Then scenario authoring with ID traceability and CE Gate coverage gap detection. Use when writing or reviewing BDD scenarios in Agent Orchestra, classifying scenarios as [auto]/[manual], managing scenario ID lifecycle, extracting scenario IDs for CE Gate pre-flight, generating Gherkin .feature files and step definitions for [auto] scenarios (Phase 2), or configuring framework runner dispatch for CE Gate (Phase 2). DO NOT USE FOR: general test strategy (use test-driven-development), or writing example-based unit tests."
---

# BDD Scenarios

Structured Given/When/Then scenario authoring with ID traceability and CE Gate coverage gap detection for Agent Orchestra.

## When to Use

- Writing G/W/T scenarios in GitHub issues (Experience-Owner upstream framing)
- Classifying scenarios as [auto] or [manual] (Issue-Planner)
- Verifying scenario ID coverage at CE Gate (Code-Conductor pre-flight)
- Per-scenario evaluation in adversarial CE prosecution (Code-Critic)
- Reviewing scenario authoring and classification quality

## G/W/T Authoring Patterns

- Scenarios use numbered IDs: S1, S2, S3…
- Heading convention: `### S{N} — {title} (Type)` where Type is Functional or Intent; emit concrete numbered IDs such as `### S1` and `### S2`, never literal `SN`
- G/W/T clauses in customer language — see **Declarative-over-Imperative** below for details
- Example template:

  ```markdown
  ### S1 — User completes onboarding (Functional)

  Given a new user has opened the application for the first time
  When they follow the onboarding prompts
  Then they reach the home screen with personalized content
  ```

- Multiple Given or Then clauses allowed; And/But connectors supported for readability
- Each scenario must be independently understandable

### Declarative-over-Imperative

Step text should describe _what the user intends_ (outcome or state change), not _how they interact with UI_ (action sequence). Declarative scenarios are more maintainable (survive UI redesigns), more reusable (same step across features), and decoupled from implementation (step definitions don't break when selectors change).

| Imperative (avoid)                                        | Declarative (preferred)                                        |
| --------------------------------------------------------- | -------------------------------------------------------------- |
| `When I click the 'Sign in with Google' button`           | `When I choose to connect my Google account`                   |
| `When the mock auth adapter returns a successful sign-in` | `Given a successful sign-in will occur for 'user@example.com'` |
| `When I navigate to '/quests'`                            | `When I visit the quests area`                                 |
| `Then I should see a 'Sign in with Google' button`        | `Then I see an option to connect my Google account`            |
| `Then I should see a green checkmark icon`                | `Then the action is confirmed`                                 |

This rule narrows the broader "no implementation details" principle (see **Gotchas** below) to two actionable categories: imperative UI-interaction verbs and test-infrastructure leakage (adapter names, mock behavior, internal paths).

**Validation scan** — when reviewing scenarios, flag any of these as signals to review (not automatic rejections — common English words like "type" or "press" may appear in legitimate customer-language scenarios; evaluate in context):

- **Imperative verbs**: `click`, `navigate`, `tap`, `type`, `scroll`, `press`, `wait`
- **Implementation nouns**: `mock`, `adapter`, `stub`, `spy`, `fixture`, path strings (e.g., `/quests`, `#submit-btn`, `.settings.json` — any string that reveals URL structure, CSS selectors, or file system paths)

This scan is especially important before Phase 2 Gherkin conversion — imperative step text produces unmaintainable step definitions.

## Scenario Type Tags

- **Functional**: Observable system behavior with clear pass/fail threshold. Use when the expected outcome is unambiguous and measurable.
- **Intent**: User-experience quality or design intent. Use when the outcome requires judgment (e.g., "feel", "clarity", "discoverability").
- Tag appears in the heading: `(Functional)` or `(Intent)`.

## Classification Rubric ([auto]/[manual])

BDD classification performed by Issue-Planner when BDD is enabled:

| Condition                                           | Classification        |
| --------------------------------------------------- | --------------------- |
| Functional + fully observable (grep/code assertion) | `[auto]`              |
| Intent + subjective judgment required               | `[manual]`            |
| Functional but requires UI interaction              | `[manual]` (override) |
| Any scenario requiring human judgment in CE Gate    | `[manual]` (override) |

Override rule: when in doubt, classify as `[manual]`. Test-Writer may reclassify `[auto]`↔`[manual]` during implementation; note the change in the plan and CE Gate evidence.

## Service Dependency Annotations

Scenarios that require external services (auth emulators, backend APIs, databases) declare dependencies via `[requires: service-name:port]` annotations on the scenario heading, after the type tag:

```markdown
### S1 — User completes sign-in (Functional) [requires: firebase-emulator:9099]

### S4 — OAuth flow with provider (Functional) [requires: auth-service:8080] [requires: api-gateway:3000]
```

- **Format**: `[requires: service-name:port]` — service-name is a human-readable label; port is the TCP port number
- **Multiple services**: Use separate `[requires:]` annotations per dependency (AND semantics — all must be available)
- **Extraction regex**: `\[requires:\s*([^:\]]+):(\d+)\]` — captures service name (group 1) and port (group 2)
- **CE Gate behavior**: Code-Conductor extracts annotations before delegation, checks each port via `check-port.ps1`, and marks scenarios with unavailable services as `INCONCLUSIVE (required service unavailable: service-name:port)` — excluding them from runner dispatch and Experience-Owner delegation. Fail-open: if `check-port.ps1` is unavailable or fails, all scenarios proceed normally.

## Scenario ID Lifecycle

- IDs are **immutable after plan approval** — once S1, S2, S3 are assigned in the issue body and the plan is approved, those IDs do not change.
- If a scenario is split during implementation, the original ID remains; new sub-scenarios get the next sequential IDs (e.g., S1 stays S1; new scenario becomes S5).
- IDs are **never reused** — when a scenario is **removed**, its ID is retired, not reassigned (the numbered `### S{N}` heading is preserved with `[REMOVED]` as the title — see ID Extraction Format below).
- **Authority: the issue body is the authoritative source for scenario IDs**. The plan cites them; it does not define them. Post-approval additions to the issue body require a plan amendment.

## ID Extraction Format

When reading scenario IDs from an issue body:

- Match the pattern `### S\d+` headings within the `## Scenarios` section. Scope the extraction to content between the `## Scenarios` heading and the next H2 heading (`##`) — do not match `### S\d+` patterns outside this boundary.
- Extract the full heading: `### S{N} — {title} (Type)` where `S{N}` is a concrete numbered ID such as `S1`
- IDs are ordinal integers starting at 1; there must be **no gaps** in the sequence.
- When a scenario is retired, keep its numbered `### S{N}` heading and replace the title with `[REMOVED]` (e.g., `### S2 — [REMOVED] (manual)`) instead of deleting the heading; this preserves the immutable ID space and allows extraction regex to still match retired-but-preserved headings.
- For CE Gate pre-flight, extract all IDs present at plan-approval time and verify each appears in Experience-Owner's evidence summary

## BDD Detection Mechanism

BDD structured scenarios are only active when the consumer repo's `copilot-instructions.md` contains a `## BDD Framework` section heading. Absence of this heading = natural-language fallback. Agents check for this heading before applying BDD-specific authoring, classification, or pre-flight behavior.

## Gotchas

- **S-IDs vs Specification's AC-NNN format**: This skill uses S-IDs (S1, S2, S3) for CE Gate scenarios. Specification agent uses `AC-NNN` for acceptance criteria. These are different namespaces — do not mix them or treat AC-NNN as a scenario ID.
- **Customer language principle**: G/W/T keywords are structural framing only. The clause content must be in customer terms — no method names, no file paths, no agent names, no implementation details. "When the system calls ExperienceOwner.FrameScenarios()" is wrong; "When the team begins feature planning" is correct. See also: **Declarative-over-Imperative** above for specific anti-patterns, preferred alternatives, and a validation scan. This gotcha states the broad principle (no implementation details); the subsection above provides actionable examples covering imperative UI verbs and test-infrastructure leakage.
- **BDD detection gating**: All BDD-specific behavior (G/W/T authoring, classification, pre-flight, per-scenario prosecution) is conditional on `## BDD Framework` presence. Repos without this section keep the existing natural-language workflow unchanged — do not apply rubric, IDs, or pre-flight to natural-language scenarios.
- **Issue-body source of truth**: The `## Scenarios` section in the GitHub issue body is the authoritative store for scenario IDs. Any abbreviated or derived authoring path (e.g., generating scenarios only in the plan's `[CE GATE]` step) **must** also write the full scenarios back into the issue body using the GitHub issue update tool — Code-Conductor's CE Gate pre-flight reads from the issue body and will treat missing issue-body scenarios as coverage gaps.
- **Phase 2 scope boundary**: Phase 2 (Gherkin conversion + framework runner integration) is documented in the `## Phase 2: Gherkin Conversion & Framework Runner` section below. Phase 1 content (authoring, traceability, coverage detection) is unchanged.

## Phase 2: Gherkin Conversion & Framework Runner

Phase 2 extends Phase 1 by converting `[auto]` scenarios into runnable `.feature` files and dispatching the consumer's BDD framework runner at CE Gate validation.

## Test-Writer Phase 2 Generation

When Test-Writer is active and Phase 2 is enabled, use this skill as the authority for:

- activation checks
- `[auto]` versus `[manual]` generation scope
- output directory selection
- `.feature` file naming
- stub idempotency
- warning behavior for `bdd: true` and unrecognized frameworks

Keep the Test-Writer agent body thin by pointing here instead of restating the full Phase 2 procedure.

### Phase 2 Detection

Phase 2 is active when **both** conditions are met in the consumer repo's `copilot-instructions.md`:

1. `## BDD Framework` section heading is present (Phase 1 condition)
2. A `bdd: {framework}` config line is present with a recognized framework name

**Known migration case — `bdd: true`**: If a consumer repo was set up under Phase 1 only and still has `bdd: true` in a comment, emit a warning: _"bdd: true detected — Phase 2 requires a recognized framework name. Set `bdd: {framework}` with one of: cucumber.js, behave, jest-cucumber, cucumber. Falling back to Phase 1 behavior."_ Then fall back to Phase 1.

**Unrecognized framework name**: If a `bdd: {framework}` line is present but the value is not in the mapping table, emit a warning: _"Unrecognized framework '{value}'. Recognized values: cucumber.js, behave, jest-cucumber, cucumber. Falling back to Phase 1 behavior."_ Then fall back to Phase 1.

**Phase-1-only repos** (heading present, no `bdd:` line): Phase 2 detection requires BOTH conditions. A repo with only the `## BDD Framework` heading is Phase 1 only — behavior is unchanged.

### Framework Mapping Table

| Framework               | Tag Format | Default Output Dir             | Runner Command Template                       | Version Check Command       |
| ----------------------- | ---------- | ------------------------------ | --------------------------------------------- | --------------------------- |
| cucumber.js             | `@S{N}`    | `features/`                    | `npx cucumber-js --tags @S{N}`                | `npx cucumber-js --version` |
| behave                  | `@S{N}`    | `features/`                    | `behave --tags @S{N}`                         | `behave --version`          |
| jest-cucumber           | `@S{N}`    | `features/`                    | `npx jest --testPathPattern features`         | `npx jest --version`        |
| cucumber (JVM Cucumber) | `@S{N}`    | `src/test/resources/features/` | `./gradlew test -Dcucumber.filter.tags=@S{N}` | `./gradlew --version`       |

> **jest-cucumber limitation**: jest-cucumber does not support per-scenario Gherkin tag filtering via CLI. Runner dispatch for jest-cucumber runs the entire `features/` directory as one suite. All `[auto]` scenarios receive the same evidence record (suite-level pass/fail rather than per-scenario). Conflict detection (`source: runner+eo, result: conflict`) is still reachable: if the suite fails and EO passes during the delegated re-exercise, the conflict is recorded at suite granularity (all `[auto]` scenarios may resolve to conflict). Per-scenario runner granularity is what is not available — the suite-level result applies uniformly to all `[auto]` scenarios.
> **cucumber (JVM Cucumber) note**: Runner commands assume Gradle (`./gradlew`). Maven-based projects will fail the pre-check and fall back to Phase 1 (EO exercises all scenarios). No runner dispatch occurs for Maven+Cucumber consumers.

### Gherkin Conversion Rules

For each `[auto]` scenario in the issue's `## Scenarios` section:

- Include a `Feature: Issue #{N} — {issue-title}` declaration at the top of every `.feature` file (required by all four supported parsers).
- Add `@S{N}` tag directly above the `Scenario:` line
- Map the scenario heading to `Scenario: {title}` (strip the `### S{N} —` prefix and type tag)
- Map G/W/T clauses to Gherkin `Given`/`When`/`Then` keywords (1:1 mapping)
- `And`/`But` connectors preserved as-is

**File layout**: One `.feature` file per issue (all `[auto]` scenarios in one file). File naming: `S{first}-S{last}-{issue-slug}.feature` (e.g., `S1-S3-task-manager-api-onboarding.feature`). Derive `{issue-slug}` from the issue title by: lowercasing, replacing spaces and non-alphanumeric characters with hyphens, collapsing consecutive hyphens, and truncating to 40 characters. Place in the framework-default output directory from the mapping table.

**Example output**:

```gherkin
Feature: Issue #42 — Task Manager API Onboarding

@S1
Scenario: User completes onboarding
  Given a new user has opened the application for the first time
  When they follow the onboarding prompts
  Then they reach the home screen with personalized content
```

**`[manual]` exclusion**: Do NOT generate `.feature` files for `[manual]` scenarios — they are exercised by Experience-Owner only.

### Step Definition Stubs

Generate step definition stubs alongside the `.feature` file **only if the stub file does not already exist**. On subsequent pipeline runs (e.g., when a new scenario is added), stubs are NOT regenerated — only the `.feature` file is regenerated. The consumer's assertion logic in existing stubs is preserved. Stubs link each `Then` clause to the scenario's Intent.

**cucumber.js** (JavaScript/TypeScript):

```javascript
const { Given, When, Then } = require("@cucumber/cucumber");

// S1 — User completes onboarding
Given(
  "a new user has opened the application for the first time",
  async function () {
    // TODO: implement setup
    return "pending";
  },
);
When("they follow the onboarding prompts", async function () {
  // TODO: implement action
  return "pending";
});
Then("they reach the home screen with personalized content", async function () {
  // TODO: implement assertion — Intent: verify onboarding completion
  return "pending";
});
```

**behave** (Python):

```python
from behave import given, when, then

# S1 — User completes onboarding
@given('a new user has opened the application for the first time')
def step_impl(context):
    pass  # TODO: implement setup

@when('they follow the onboarding prompts')
def step_impl(context):
    pass  # TODO: implement action

@then('they reach the home screen with personalized content')
def step_impl(context):
    pass  # TODO: implement assertion — Intent: verify onboarding completion
```

**jest-cucumber**: Use `loadFeature` + `defineFeature` pattern with steps mapped to `@S{N}` scenario.

**cucumber (JVM Cucumber)** (Java):

```java
import io.cucumber.java.en.Given;
import io.cucumber.java.en.When;
import io.cucumber.java.en.Then;

public class StepDefinitions {

    // S1 — User completes onboarding
    @Given("a new user has opened the application for the first time")
    public void givenNewUserOpened() {
        throw new io.cucumber.java.PendingException(); // TODO: implement setup
    }

    @When("they follow the onboarding prompts")
    public void whenTheyFollowPrompts() {
        throw new io.cucumber.java.PendingException(); // TODO: implement action
    }

    @Then("they reach the home screen with personalized content")
    public void thenTheyReachHomeScreen() {
        throw new io.cucumber.java.PendingException(); // TODO: implement assertion — Intent: verify onboarding completion
    }
}
```

### Runner Dispatch Protocol

Code-Conductor dispatches the framework runner at CE Gate. Process:

1. **Pre-check**: Run version check command from mapping table. Non-zero exit → log warning, fall back to Phase 1 (EO exercises all scenarios).
2. **Per-scenario dispatch**: For each `[auto]` scenario, run the runner command with `@S{N}` tag filtering. Capture exit code + stdout + stderr.
3. **Evidence capture**: Record as a unified evidence record per scenario.
4. **Conditional EO delegation**: Runner passed all `[auto]` → send only `[manual]` to EO. Some `[auto]` failed → add failed `[auto]` to EO list. Pre-check failed → send all to EO.
5. **Evidence merge**: Combine runner evidence (for `[auto]`) with EO evidence (for `[manual]`) into the unified evidence record.

> **Note on pending stubs**: Step definition stubs are generated as pending (e.g., `return 'pending'` in cucumber.js). **The consumer must implement the step definitions before runner dispatch produces per-scenario evidence at CE Gate time.** On the first CE Gate run after stub generation (before stubs are implemented), all `[auto]` scenarios will fail the runner dispatch — this is expected behavior. Code-Conductor will treat all `[auto]` failures as delegation triggers and fall back to EO exercising all scenarios (same as Phase 1).

**Unified evidence record schema** (5 fields):

| Field           | Type   | Description                           |
| --------------- | ------ | ------------------------------------- |
| `scenario_id`   | string | Scenario ID (e.g., `S1`)              |
| `source`        | enum   | `runner` \| `eo` \| `runner+eo`       |
| `result`        | enum   | `pass` \| `fail` \| `conflict`        |
| `detail`        | string | Summary or first stderr line          |
| `raw_exit_code` | int    | Runner exit code (runner source only) |

**Evidence merge rules**:

- Runner evidence is primary for `[auto]` scenarios; EO evidence is primary for `[manual]`.
- Same-scenario conflict (runner-fail + EO-pass — EO exercises a failed `[auto]` scenario and yields a different result) → set `source: runner+eo`, `result: conflict` — passed to Code-Critic with both records. (Note: runner-pass + EO-fail is unreachable — runner-passed `[auto]` scenarios are excluded from EO delegation.)

**Result format examples**:

- `S1: runner-pass (exit 0, 1 scenario passed)`
- `S2: runner-fail (exit 1, error: AssertionError: expected 200 but got 404)`

### Runner Evidence in CE Prosecution

Code-Critic evaluates runner evidence using the `source` field from the unified evidence record:

- `source: runner`, `result: pass` → strong evidence for **Functional** lens (exit 0 + passing assertions)
- `source: runner`, `result: fail` → classify as **Concern** with error context from `detail` field
- `source: runner+eo`, `result: conflict` → **Concern** (not Issue) — include both records in findings, request clarification from Experience-Owner
- `source: eo` (Phase 1 behavior or runner fallback) → existing per-scenario evaluation unchanged
