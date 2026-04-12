# Design: RC Conformance Gate

## Summary

The RC Conformance Gate is a post-implementation check that verifies delivered code satisfies the current step's Requirement Contract (RC) acceptance criteria before step advance. It fires after the convergence gate passes (build + tests green) and catches obvious divergences between what was contracted and what was built — missing UI elements, wrong copy, omitted affordances — before they propagate to later steps or the CE Gate.

---

## Design Decisions

| # | Decision | Choice | Rationale |
|---|----------|--------|-----------|
| D1 | Gate placement | After convergence gate passes (per parallel-execution SKILL), before any step-advance checkpoint | Latest stable point with full test/build confidence; convergence gate confirms build + test pass, so RC check evaluates implementation that is already structurally sound |
| D2 | Evaluation mechanism | CC reads AC items, inspects changed files via `get_changed_files`, evaluates each AC item | Leverages existing VS Code tool (no new tooling); provides file-level evidence; keeps the protocol inside CC where step-level context lives |
| D3 | Output format | Pass: single log line with item count; Fail: bullet list with customer-outcome gap descriptions (RC expectation vs. actual) | Minimizes noise on pass; forces customer-visible language on fail — aligns with CE Gate intent verification |
| D4 | Correction routing | Conditional sequential pair: Code-Smith first → re-evaluate → Test-Writer only if divergence persists, with explicit "Re-derive from RC" instruction | Two-agent chain matches the existing parallel-execution triage taxonomy; Test-Writer re-derivation prevents rubber-stamping the corrected implementation |
| D5 | Loop budget | 1 dedicated cycle (Code-Smith + optional Test-Writer = 1 cycle), outside the main 3-cycle convergence budget | Prevents RC correction from consuming convergence budget cycles; single cycle keeps escalation fast |
| D6 | Skip condition | No RC check when step has no AC items (detection: absence of "Acceptance Criteria" / "AC" section in RC block) | Steps without AC items produce no evaluable criteria; forcing the gate would yield a vacuous pass or a false negative |
| D7 | Triage taxonomy expansion | 4-class: `code defect`, `test defect`, `harness/env defect`, `rc-divergence` | Clean signal: `rc-divergence` is a distinct failure mode (delivered code ≠ contract) vs. code defect (code doesn't compile/run), test defect (test is wrong), or harness-env (tooling failure) |
| D8 | Fidelity scope | Obvious divergences only (missing UI elements, wrong copy, omitted affordances); subtle logic bugs stay in Tier 4 + CE Gate | Prevents false-positive overreach; keeps the gate fast and high-signal |

## Implementation

### Gate Protocol (Code-Conductor)

The RC conformance gate is embedded in Code-Conductor's "Execute Each Step" loop, after the convergence gate and incremental validation pass:

1. **Read** the step's RC AC items from the plan
2. **Inspect** changed files via `get_changed_files`, filtering to the step's target files
3. **Evaluate** each AC item against current file state
4. **Output**:
   - Pass: `RC conformance: ✅ all {N} AC items satisfied`
   - Fail: `RC conformance: ❌ {N} of {M} AC items divergent` + bullet list describing each gap in customer-outcome terms (RC expectation vs. actual)
5. **Skip**: when the step's RC block has no "Acceptance Criteria" / "AC" section
6. **On fail**: classify as `rc-divergence` and route per the correction protocol below
7. **Budget**: 1 dedicated correction cycle, outside the main 3-cycle convergence budget; if unresolved after 1 cycle, escalate via `#tool:vscode/askQuestions` with unresolved AC items and recommended options
8. **Fidelity scope**: targets obvious divergences only; subtle logic bugs remain the domain of Tier 4 adversarial review and CE Gate

### Triage Taxonomy (Code-Conductor)

The Failure Triage Rule uses a 4-class taxonomy:

| Class | Meaning | Routing |
|-------|---------|---------|
| `code defect` | Code doesn't compile/run correctly | Code-Smith |
| `test defect` | Test assertion is wrong | Test-Writer |
| `harness/env defect` | Tooling or environment failure | Responsible specialist |
| `rc-divergence` | Delivered code ≠ Requirement Contract | Conditional sequential pair (see below) |

**`rc-divergence` correction protocol**: Code-Smith first (fix implementation to match RC) → CC re-runs Tier 1 validation → CC re-evaluates **all** AC items (not just previously-divergent ones) → if all satisfied, advance → if divergence persists, dispatch Test-Writer with instruction: "Re-derive test assertions from the Requirement Contract, not from the corrected implementation" → CC re-runs Tier 1 validation and re-evaluates all AC items.

### Build-Test Orchestration (parallel-execution SKILL)

The parallel-execution SKILL protocol was extended with RC conformance integration:

- **Step 5** (classify failures): expanded to include `rc-divergence` as a fourth failure class alongside `code defect`, `test defect`, and `harness/env defect`
- **Step 6** (route corrections): added `rc-divergence` routing — conditional sequential pair as described above
- **Step 8** (new): "Run RC conformance check" — CC evaluates the step's RC AC items against delivered code after convergence; divergences route as `rc-divergence` via step 6
- **Convergence Gate**: added note that the RC conformance check (step 8) fires after convergence, before step advance
- **Loop Budget**: added dedicated 1-cycle RC correction budget outside the main 3-cycle budget
- **Gotchas**: added row for RC conformance divergence misrouted as `code defect` — prevention is to always use the `rc-divergence` class for RC divergences

## Cross-References

- Code-Conductor: `RC conformance gate` sub-bullet in Execute Each Step
- Code-Conductor: `rc-divergence` in Failure Triage Rule
- parallel-execution SKILL: steps 5–8, Convergence Gate, Loop Budget, Gotchas

## Source

Issue #326 (Closes #283, #284)
