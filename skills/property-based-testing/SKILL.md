---
name: property-based-testing
description: "Incremental rollout policy for property-based testing that preserves readable example-based tests while adding invariant-focused randomized verification. Use when adding randomized testing, validating input ranges, or verifying mathematical properties. DO NOT USE FOR: example-based unit/integration tests or TDD workflow (use test-driven-development), React component tests (use ui-testing), or E2E browser tests (use webapp-testing)."
---

# Property-Based Testing Skill

Use PBT as a complement to example-based tests.

## Rollout Policy

1. Start in domain logic with pure invariants first.
2. Keep existing unit/integration tests as readability and regression anchors.
3. Begin with small run counts in PR CI, then increase in scheduled or nightly runs.
4. Require reproducible seeds in all failure reports.
5. Avoid initial rollout in UI/adapters until core invariants are stable.

## Guardrails

- Do not replace readable example-based tests with PBT.
- Keep properties behavior-focused, not implementation-coupled.
- Treat flaky generators/shrinking issues as `test defect` and route for test refinement.
- If infrastructure instability dominates, classify as `harness/env defect` and fix the harness before expanding PBT scope.

## Adoption Guidance

- Start with a small invariant set and expand gradually.
- Add PBT where domain rules are stable and deterministic.
- Scale run volume only after repeated stable results.

## Gotchas

| Trigger                                                                     | Gotcha                                                                                                  | Fix                                                                                              |
| --------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------ |
| Replacing readable example-based tests with PBT to be "more thorough"       | Example-based tests serve as readable documentation and regression anchors; removing them loses context | PBT complements, never replaces, example-based tests                                             |
| Writing a property that asserts internal computation steps                  | Property breaks on any internal refactor, same flaw as testing implementation details                   | Keep properties behavior-focused; test invariants (observable outcomes), not mechanisms          |
| Adding PBT to UI or adapter layers before core domain invariants are stable | Unstable core means properties change constantly; high churn                                            | Start in domain logic with pure invariants; expand outward after stability                       |
| Setting `runs: 1000` in CI from the start                                   | Slow CI blocks the team immediately on PBT adoption                                                     | Start small in CI (50–100 runs); increase in scheduled or nightly runs after stability confirmed |
| Not requiring reproducible seeds in failure reports                         | Intermittent PBT failure looks flaky but is reproducible with the right seed                            | Require seed capture in all failure reports from day one                                         |
| Treating intermittent PBT failures as domain bugs without triage            | Root cause may be the generator or shrinking logic, not domain code                                     | Classify as `test defect`, route to test refinement before investigating domain code             |
