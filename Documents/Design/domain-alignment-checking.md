# Design: Domain Alignment Checking

## Summary

Two complementary guardrails that catch cross-function input domain mismatches: (1) a gated TDD RED phase step ("Domain Peer Check") that prompts authors to compare input ranges before writing tests, and (2) a Code-Critic sub-perspective (§1d "Domain Alignment Verification") that prompts reviewers to check whether multiple functions operating on the same field agree on accepted input ranges. Both were motivated by a defect where three code review passes missed a validator/parser range mismatch that was only found at the CE Gate.

---

## Design Decisions

| # | Decision | Choice | Rationale |
|---|----------|--------|-----------|
| D1 | Placement in TDD workflow | Step 2 (new), before "Write the Test" | Proactive — resolve range mismatches before RED tests are written; inserting earlier ensures tests don't encode the wrong domain assumptions |
| D2 | Placement in Code-Critic | §1d sub-perspective under §1 Architecture | Reactive complement to D1; sub-perspective keeps the "7 code perspectives" count accurate across all reference locations; §1b/§1c precedent for unnamed sub-perspectives |
| D3 | "Same field" heuristic | Three criteria: (a) same parameter/field name, (b) same documented concept (different names allowed), (c) one function's output feeds the other's input | Criteria must be concrete enough for authors to apply without judgment ambiguity; "when uncertain, err toward checking" catchall covers edge cases |
| D4 | Scope | PR diff + existing codebase (not PR-only) | A new validator can conflict with an existing parser not in the diff; PR-only scope would reproduce the original defect |
| D5 | Gate condition | Function "validates, parses, deserializes, or constrains" a field also handled by another function | Covers the class broadly: range-clampers / normalizers included via "constrains"; vocabulary symmetry between TDD gate and §1d gate maintained |
| D6 | Intentional differences | Document in plan step or inline code comment | Light-touch — no new artifact required; co-location with the divergent function keeps context together |
| D7 | Discovery mechanism | Grep field name for criterion (a); consult plan/design doc for criterion (b); trace call chain for criterion (c) | Each heuristic has a distinct discovery method; grep alone is insufficient for (b) and (c) |
| D8 | Sub-steps symmetry | TDD and §1d align on enumerate → compare → resolve/document | Parallel structure reinforces that both guardrails are checking the same property at different lifecycle stages |

---

## The Root-Cause Bug Class

The defect pattern: two functions in the same codebase accept inputs "about" the same concept (e.g., a game seed), but their validation/parsing happens independently, each with different accepted value ranges. A test written against one function passes; a test written against the other passes; but the system fails when data flows from one to the other. This class of bug survives unit tests and 3-pass code review because no step asks: "do both functions agree on what values are valid?"

**Historical instance**: `validateGameSetup` accepted `seed: -1` (interpreting negative seeds as "random"); `parseSeedParam` accepted only `[0, 4294967295]`. Three Code-Critic passes missed the mismatch; it was caught by the CE Gate's Error States lens.

---

## Rejected Alternatives

| Alternative | Rejected because |
|---|---|
| Single guardrail (TDD-only or review-only) | Two stages reduce risk of each stage being skipped or glossed over; defense-in-depth |
| PR-only scope | Wouldn't catch conflicts with existing functions not in the diff |
| §1 top-level (new §8) | Would change "7 code perspectives" count across 5 reference locations; not warranted for an architectural sub-check |
| Require formal documentation artifact for intentional differences | Overhead disproportionate to benefit; plan step or inline comment achieves the same traceability goal |
