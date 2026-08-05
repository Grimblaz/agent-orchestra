# Quality Gates Reference

## Quality Hierarchy

Quality gates are enforced in priority order:

| Priority     | Gate             | Tool   | Threshold | Why                              |
| ------------ | ---------------- | ------ | --------- | -------------------------------- |
| 🥇 PRIMARY   | Mutation Testing | PIT    | ≥80%      | Validates tests catch real bugs  |
| 🥈 SECONDARY | Code Coverage    | JaCoCo | ≥80%      | Ensures code is exercised        |
| 🥉 BASELINE  | Added Failures   | JUnit  | 0 vs. baseline | Basic correctness           |

## Why This Order?

**Coverage alone is insufficient:**

- 100% coverage means code ran, not that it was verified
- Tests can cover code without meaningful assertions
- "Coverage theater" - high numbers, low confidence

**Mutation testing validates test quality:**

- Introduces small bugs (mutants) into code
- Checks if tests catch them
- Surviving mutants = weak tests

## Threshold Breakdown

| Metric            | Threshold | Scope          | Notes                 |
| ----------------- | --------- | -------------- | --------------------- |
| Mutation Score    | ≥80%      | Core logic     | Primary quality gate  |
| Line Coverage     | ≥80%      | Core logic     | All code exercised    |
| Branch Coverage   | ≥80%      | Core logic     | All conditions tested |
| Added Failures    | 0         | All            | Differential against a named baseline commit **that predates the change** (branch point or merge base, never the run's own post-change commit), not an absolute floor — a failure already present at that baseline is named and routed, never a blocker on this change (`skills/verification-before-completion/SKILL.md` § The Completion Account) |

## Tiered Mutation Strategy

For larger projects, consider tiered approaches:

### Tier 1: PR Validation (Fast)

- **Scope**: Changed files only
- **Time**: 2-5 minutes
- **Blocking**: Yes (≥80% required)

### Tier 2: Nightly Build (Comprehensive)

- **Scope**: Core modules
- **Time**: 15-30 minutes
- **Purpose**: Catch regressions

### Tier 3: Weekly (Full)

- **Scope**: Entire codebase
- **Time**: 30-60+ minutes
- **Purpose**: Baseline quality metrics

## Configuration Example (Gradle)

```groovy
pitest {
    targetClasses = ['com.example.service.*', 'com.example.domain.*']
    mutationThreshold = 80
    coverageThreshold = 80
    timestampedReports = false
}
```

## Related

- [commands.md](./commands.md) - How to run quality gates
- [test-patterns.md](./test-patterns.md) - Writing tests that pass mutation
- [anti-patterns.md](./anti-patterns.md) - Why tests fail mutation
