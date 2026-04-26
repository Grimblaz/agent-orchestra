# Customer Experience Gate Orchestration Protocol

This reference owns the CE Gate orchestration details extracted for the customer-experience composite. Code-Conductor still owns when the gate runs and the PR body that records the outcome.

> **Survival**: `SMC-03` covers the design cache split: durable issue body or design marker first, platform-local cache optional. `SMC-08` covers durable phase-completion markers; CE evidence artifacts and PR-body entries are outputs, not a separate resume store.

See [defect-response.md](defect-response.md) for remediation, graceful-degradation, and CE or proxy prosecution re-activation details.

## Customer Experience Gate (CE Gate)

Run this gate as the final step before PR creation (Tier 4, after the post-fix targeted prosecution pass - or after Code-Review-Response judgment if post-fix was not triggered).

### Surface Identification

Read the plan's `[CE GATE]` step to identify the customer surface. Pass this surface type information to Experience-Owner when delegating evidence capture (step 3 of the Scenario Exercise Protocol). If no `[CE GATE]` step exists, infer from the change type and include the inferred surface type in the Experience-Owner delegation:

Load `skills/routing-tables/SKILL.md` and use `Invoke-RoutingLookup -Table surface_identification -Key Surface -Value "{surface}"` for the canonical surface-to-tool mapping in `skills/routing-tables/assets/routing-config.json`. Preserve the same behavior: native browser tools remain the primary Web UI path with Playwright MCP fallback, terminal invocations remain the default for REST/GraphQL, CLI, SDK, and batch surfaces, and `No customer surface` still emits `⏭️ CE Gate not applicable - {reason}`.

### Scenario Exercise Protocol

1. Read the `[CE GATE]` scenarios from the plan step (natural language descriptions)
   1. **Service dependency extraction**: Parse `[requires: service-name:port]` annotations from the issue body `## Scenarios` heading text using regex `\[requires:\s*([^:\]]+):(\d+)\]` (see bdd-scenarios skill § Service Dependency Annotations). Build a scenario-ID -> required-services map. Multiple `[requires:]` on one heading use AND semantics.
   2. **Service pre-check**: For each unique port in the map, run `pwsh -NoProfile -NonInteractive -File skills/terminal-hygiene/scripts/check-port.ps1 -Port {port}` and read `InUse` from the JSON output. Unavailable ports -> mark affected scenarios `INCONCLUSIVE (required service unavailable: service-name:port)` in the evidence record and exclude them from runner dispatch (step 3) and EO delegation (step 4). Report: `"Service pre-check: {N} of {M} required services available. INCONCLUSIVE: {list}."` Fail-open: if `check-port.ps1` is absent or fails, proceed with all scenarios. All-unavailable -> `#tool:vscode/askQuestions` with options: "Start services and retry" (recommended), "Proceed without service-dependent scenarios", "Abort CE Gate".
2. Establish the **design intent reference**: read the `Design Intent` field from the plan's `[CE GATE]` step (if present); otherwise use the current issue's durable design snapshot - prefer the latest `<!-- design-issue-{ID} -->` handoff comment when one exists, otherwise read the issue body directly. Platform-local design caches may be used as an optimization when available, but they are not required. Understand what the change was supposed to accomplish for the user - not just what it does technically
3. **BDD Phase 2 Runner Dispatch** (conditional - skip entirely when Phase 2 is not active; Phase 2 requires `## BDD Framework` heading AND `bdd: {framework}` line with recognized framework in consumer repo's `copilot-instructions.md`):
   1. **Phase 2 detection**: read `bdd: {framework}` from consumer `copilot-instructions.md`. Missing heading or heading-only without `bdd:` line -> skip this step entirely, proceed to step 4 with all scenarios (Phase 1 behavior unchanged). `bdd: true` detected -> emit warning _"bdd: true detected - Phase 2 requires a recognized framework name. Set `bdd: {framework}` with one of: `cucumber.js`, `behave`, `jest-cucumber`, `cucumber`. Falling back to Phase 1 behavior."_ then skip. Unrecognized framework -> emit warning per bdd-scenarios skill Phase 2 Detection rules, then skip.
   2. **Runner pre-check**: run version check command from bdd-scenarios skill framework mapping table. Non-zero exit -> log warning `"Runner pre-check failed for {framework} - falling back to Phase 1 (EO exercises all scenarios)"`, skip remaining sub-steps, proceed to step 4 with all scenarios.
   3. **Per-scenario dispatch**: for each `[auto]` scenario, run the runner command with `@S{N}` tag filtering via `run_in_terminal`; capture exit code + stdout + stderr. **Exception**: `jest-cucumber` does not support tag filtering - run `npx jest --testPathPattern features` once as a suite-level dispatch and record the same suite evidence for all `[auto]` scenarios (see skill framework mapping table limitation note).
   4. **Evidence capture**: record a unified evidence record per scenario - schema: `scenario_id: S{N}`, `source: runner`, `result: pass | fail`, `detail: {summary or first stderr line}`, `raw_exit_code: {int}`.
   5. **Conditional EO delegation**: all `[auto]` runners passed -> delegate only `[manual]` scenarios to EO in step 4; any `[auto]` runner failed -> add failed `[auto]` to EO delegation list; pre-check failed -> delegate all.
   6. **Evidence merge**: after step 4 (EO delegation) returns, merge EO evidence for all delegated scenarios. Reachable conflict: runner-fail `[auto]` scenario where EO yields a pass -> `source: runner+eo`, `result: conflict`. (Note: runner-pass + EO-fail is unreachable - runner-passed `[auto]` scenarios are excluded from EO delegation by sub-step v above.)
4. **Delegate CE Gate evidence capture to Experience-Owner** (subagent): Call Experience-Owner as a subagent via the `agent` tool, passing: (a) the issue number, (b) the scenario list determined in step 3 (Phase 2: conditional subset per runner dispatch; Phase 1: all scenarios from the `[CE GATE]` plan step), (c) the named design decisions (D1-DN) from the issue body, and (d) the design intent reference. Experience-Owner exercises scenarios using appropriate tools, performs D1-DN systematic verification, performs exploratory validation, and returns a structured evidence summary (scenario results, D1-DN verification outcomes, exploratory observations, captured screenshots/output). **Code-Conductor does NOT exercise scenarios itself - delegation is mandatory.** If Experience-Owner returns graceful-degradation output (environment unavailable), emit the appropriate `⚠️ CE Gate skipped` marker and proceed.
5. **BDD pre-flight coverage check** (conditional - skip when the consumer repo's `copilot-instructions.md` does not contain a `## BDD Framework` section heading; when BDD is active, read scenario IDs from the `## Scenarios` section of the issue body, not from the plan; max 2 recovery cycles, independent of Track 1's 2-cycle budget): Read all scenario IDs from the issue body by matching `### S\d+` headings within the `## Scenarios` section. Scope the extraction to content between the `## Scenarios` heading and the next H2 heading - do not match `### S\d+` patterns outside this boundary. **Exclude headings whose title contains `[REMOVED]`** - these are retired scenarios preserved as tombstones for ID-space immutability; they are not exercised by Experience-Owner and must not trigger a coverage gap. For each remaining ID, verify it appears in the **unified evidence record** (runner evidence from step 3 and/or Experience-Owner evidence from step 4). If all IDs are present, proceed to step 6. If any IDs are missing, invoke `#tool:vscode/askQuestions` with three options: "Re-exercise missing scenario" (re-delegate to Experience-Owner with only the missing IDs; merge evidence with the first run), "Waive with documented reason" (proceed with a documented gap), or "Abort CE Gate (stop recovery - PR proceeds with abort marker)" (emit `❌ CE Gate aborted - pre-flight: {N} of {M} scenarios uncovered after {cycles} recovery cycles` in the PR body; PR creation may continue with the abort marker and documented reason). After 2 recovery cycles, if scenarios remain uncovered, present final options via `#tool:vscode/askQuestions`: `Waive with documented reason` (recommended) or `Abort CE Gate (stop recovery - PR proceeds with abort marker)`. When BDD is enabled, include a per-scenario coverage table in the PR body (see PR Body CE Gate Entry). For waived scenarios, use `⚠️ Waived - {reason}` in the Result column. For scenarios uncovered at CE Gate abort time, use `❌ Not covered - {reason}` in the Result column.
6. **Invoke CE prosecution pipeline**: Pass the unified evidence summary (runner evidence + Experience-Owner evidence) to Code-Critic with the marker `"Use CE review perspectives"`. Code-Critic reviews adversarially across 3 lenses (Functional + Intent + Error States) and emits a prosecution findings ledger.
7. **Defense pass**: Invoke Code-Critic with the CE prosecution ledger and marker `"Use defense review perspectives"`.
8. **Judge pass**: Invoke Code-Review-Response with both the CE prosecution ledger and defense report. Judge rules final and emits score summary with CE intent match level.
9. CE Gate result markers (emitted by the judge in conjunction with Code-Conductor's read of the verdict):
   - `✅ CE Gate passed - intent match: strong` - all scenarios passed, no defects found, design intent fully achieved
   - `✅ CE Gate passed - intent match: partial` - scenarios pass; intent partially achieved (in-PR fix routed to Code-Smith by default; follow-up issue at Code-Conductor's discretion)
   - `✅ CE Gate passed - intent match: weak` - scenarios pass; intent not met (in-PR fix routed to Code-Smith by default; follow-up issue at Code-Conductor's discretion)
   - `✅ CE Gate passed after fix - intent match: {strong|partial|weak}` - defects found and resolved within loop budget
   - `⚠️ CE Gate skipped - {reason}` - tool unavailable or environment issue
   - `❌ CE Gate aborted - {reason}` - pre-flight uncovered scenarios not resolved within recovery budget
   - `⏭️ CE Gate not applicable - {reason}` - no customer surface for this change

### Intent Match Rubric

Apply this rubric after exercising scenarios. **Default to `strong` unless a specific, articulable criterion below is violated** - "feels off" is not sufficient.

| Level       | Criteria                                                                                                                                                                                                                                  | When to emit                                                       |
| ----------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------ |
| **strong**  | All of: (a) behavior matches what the design described, (b) user-facing language/feedback is clear and specific, (c) flow follows the path the design intended with no unexpected detours                                                 | Default - emit unless a specific deviation below is identified     |
| **partial** | Any of: (a) behavior works but the user path diverges from design intent (extra steps, confusing order), (b) feedback is generic where the design specified contextual messaging, (c) edge case handling exists but is rough or unhelpful | One or more specific deviations articulable; core intent still met |
| **weak**    | Any of: (a) feature works but is difficult to discover or understand without documentation, (b) error states are swallowed or show technical details instead of user guidance, (c) flow contradicts the design's stated user experience   | Core intent not met; user would likely be confused or frustrated   |

### Surface-Specific Intent Verification

Use these surface-specific criteria to identify _what_ to evaluate; then apply the Intent Match Rubric above to determine _which level_ to assign:

| Surface              | Intent verification criteria                                                                                                                 |
| -------------------- | -------------------------------------------------------------------------------------------------------------------------------------------- |
| **Web UI**           | Flow matches design's described user journey; visual hierarchy supports intended emphasis; feedback messages match design spec               |
| **REST/GraphQL API** | Response structure is ergonomic for the consumer; error responses include actionable guidance per design; field naming conveys domain intent |
| **CLI**              | Help text accurately describes design-intended usage; output format serves the user's workflow; error messages guide correction              |
| **SDK/Library**      | API surface is discoverable; method names convey intent per design; error types are domain-specific, not generic                             |
| **Batch/Pipeline**   | Output/logs are interpretable by the intended operator; failure modes match what the design specified                                        |

### PR Body CE Gate Entry

Always include in the PR body:

- CE Gate result marker (one of the markers above, with intent match level for passing gates)
- Scenarios exercised: when BDD is enabled, use the per-scenario coverage table format below; otherwise, use the current brief list format
- Track 2 outcome: `Process-Review: no systemic gap found` or link to created follow-up issue

Read the `Class` value (`[auto]` or `[manual]`) from the plan's `[CE GATE]` step scenario entries (e.g., `S1: {description} [auto]`). Read the `Type` value (`Functional` or `Intent`) from the scenario heading `### SN - {title} (Type)` in the issue body's `## Scenarios` section. When BDD is enabled, replace the "Scenarios exercised (brief list)" with the per-scenario coverage table below:

| ID  | Type       | Class    | Result    | Evidence            | Source |
| --- | ---------- | -------- | --------- | ------------------- | ------ |
| S1  | Functional | [auto]   | ✅ Passed | {brief description} | Runner |
| S2  | Intent     | [manual] | ✅ Passed | {brief description} | EO     |

### PR Body Review Mode

Always include a visible `## Review Mode` section in the PR body.

Use this text for the standard path:

```markdown
## Review Mode

Full review pipeline completed: 3 prosecution passes, 1 defense pass, 1 judge pass.
```

Use this text for the abbreviated path:

```markdown
## Review Mode

Lite review pipeline completed via `/orchestra:review-lite`: 1 compact prosecution pass, 1 defense pass, 1 judge pass.
```

### PR Body Adversarial Review Scores

Always include the adversarial review score summary table from the judge's score summary output:

```markdown
## Adversarial Review Scores

| Stage           | Prosecutor                | Defense                                 | Judge rulings |
| --------------- | ------------------------- | --------------------------------------- | ------------- |
| Code Review     | {pts} pts ({N} sustained) | {pts} pts ({N} disproved, {N} rejected) | {N} rulings   |
| CE Review       | {pts} pts ({N} sustained) | {pts} pts ({N} disproved, {N} rejected) | {N} ruling(s) |
| Post-fix Review | {pts} pts ({N} sustained) | {pts} pts ({N} disproved, {N} rejected) | {N} ruling(s) |
```

For lite review mode, replace the `Code Review` row label with `Code Review (lite)`. The CE Review and Post-fix Review row labels stay unchanged.

If a stage did not run (e.g., CE Gate not applicable, post-fix review not triggered), note it as `⏭️ N/A`.

### Prosecution Depth Summary

After prosecution depth setup and before PR creation, emit a Prosecution Depth Summary in both the conversation output and the PR body.

**Conversation output** (brief):

```text
Prosecution depth: 5 full, 1 light, 1 skip
```

**PR body section** (after Adversarial Review Scores, before Pipeline Metrics):

```markdown
## Prosecution Depth Summary

| Category               | Depth | Rationale                                 |
| ---------------------- | ----- | ----------------------------------------- |
| architecture           | full  | -                                         |
| security               | light | sustain rate 0.12 / 22 effective findings |
| performance            | full  | -                                         |
| pattern                | skip  | sustain rate 0.03 / 35 effective findings |
| implementation-clarity | full  | -                                         |
| script-automation      | full  | insufficient data (8 effective)           |
| documentation-audit    | full  | insufficient data (3 effective)           |

Re-activated categories (if any): {list with trigger source, or "none"}
```

If prosecution depth setup was skipped (safe fallback), emit: `Prosecution depth: all full (fallback - aggregate script unavailable)`
