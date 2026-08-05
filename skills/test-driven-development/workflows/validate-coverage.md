# Validate Coverage (Quality Gates)

## Overview

After tests pass, validate they meet quality thresholds before considering the feature complete.

## Quality Hierarchy

| Priority     | Gate       | Threshold | Command                          |
| ------------ | ---------- | --------- | -------------------------------- |
| 🥇 PRIMARY   | Mutation   | ≥80%      | `./gradlew pitest`               |
| 🥈 SECONDARY | Coverage   | ≥80%      | `./gradlew jacocoTestReport`     |
| 🥉 BASELINE  | Added Failures | 0 vs. baseline | `./gradlew test`            |

## Workflow Steps

### 1. Run Tests

```bash
./gradlew test
```

**Expected:** no failure this change introduced. Compare against the same command at a named baseline commit rather than requiring an absolute green — a failure already present at that baseline is named and routed, not a blocker on this change.

### 2. Check Code Coverage

```bash
./gradlew test jacocoTestReport
```

**View report:** `build/reports/jacoco/test/html/index.html`

**Target:** ≥80% line and branch coverage for core logic

### 3. Run Mutation Testing

Mutation testing is the **primary quality gate**—it validates that your tests actually catch bugs.

```bash
./gradlew pitest
```

**View report:** `build/reports/pitest/index.html`

**Target:** ≥80% mutation score

### 4. Interpret Results

#### Coverage Report

```text
Element          Missed   Cov.
UserService         0/15   100%
UserController      2/20    90%
```

#### Mutation Report

```text
Mutants: 50 generated, 45 killed, 5 survived
Mutation Score: 90%
```

**Surviving mutants** indicate weak tests—the code was changed but tests still passed.

### 5. Fix Surviving Mutants

For each surviving mutant:

1. Read the mutation description
2. Write a test that would catch this bug
3. Verify the new test kills the mutant

**Example surviving mutant:**

```text
Replaced return value with null → SURVIVED
Location: UserService.getUserById line 15
```

**Fix:** Add a test that verifies the return value is not null:

```java
@Test
void getUserByIdReturnsNonNull() {
    when(repository.findById("123")).thenReturn(Optional.of(new User("123", "test")));

    User result = service.getUserById("123");

    assertThat(result).isNotNull();
}
```

## Quick Reference

| Check    | Command                         | Threshold |
| -------- | -------------------------------- | --------- |
| Tests    | `./gradlew test`                | 0 added failures vs. baseline |
| Coverage | `./gradlew jacocoTestReport`    | ≥80%      |
| Mutation | `./gradlew pitest`              | ≥80%      |

## Checklist

- [ ] No test failure this change introduced, against a named baseline commit; pre-existing failures named and routed (`skills/verification-before-completion/SKILL.md` § The Completion Account)
- [ ] Coverage ≥80% for core logic
- [ ] Mutation score ≥80%
- [ ] No surviving mutants in critical paths

## Next Steps

After validation passes:

- If code needs cleanup → [refactor-safely.md](./refactor-safely.md)
- If complete → Ready for PR

## Related

- [../references/quality-gates.md](../references/quality-gates.md) - Threshold details
- [../references/commands.md](../references/commands.md) - All test commands
