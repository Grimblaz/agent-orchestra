# Test Commands Reference

> **Note**: Commands shown for Gradle with common plugins. Adapt for your build system.

## Unit Testing

```bash
# Run all unit tests
./gradlew test

# Run specific test class
./gradlew test --tests "UserServiceTest"

# Run specific test method
./gradlew test --tests "UserServiceTest.returnsUserWhenFoundById"

# Run tests matching pattern
./gradlew test --tests "*Service*"
```

**Expected Output:**

```text
[INFO] Tests run: 45, Failures: 0, Errors: 0, Skipped: 0
[INFO] BUILD SUCCESS
```

**Time:** Typically < 30 seconds for unit tests

---

## Coverage Testing

```bash
# Run tests with coverage
./gradlew test jacocoTestReport

# View report
# Open: build/reports/jacoco/test/html/index.html
```

**Target:** ≥80% line and branch coverage

---

## Mutation Testing

```bash
# Run mutation tests
./gradlew pitest

# View report
# Open: build/reports/pitest/[timestamp]/index.html
```

**Time:** 5-30 minutes depending on codebase size

**Target:** ≥80% mutation score

---

## Integration Testing

```bash
# Run integration tests
./gradlew integrationTest

# Or if using test sets
./gradlew test integrationTest
```

---

## Continuous Integration

### Combined Validation

```bash
# Gradle: Full validation pipeline
./gradlew clean test jacocoTestReport pitest
```

### GitHub Actions Example

```yaml
- name: Run Tests
  run: ./gradlew test jacocoTestReport

- name: Mutation Testing
  run: ./gradlew pitest
  if: github.event_name == 'pull_request'
```

---

## Quick Reference

| Task                   | Gradle Command                          |
| ---------------------- | --------------------------------------- |
| Run all tests          | `./gradlew test`                        |
| Run specific test      | `./gradlew test --tests "ClassName"`   |
| Coverage report        | `./gradlew jacocoTestReport`            |
| Mutation testing       | `./gradlew pitest`                      |
| Integration tests      | `./gradlew integrationTest`             |
| Full validation        | `./gradlew clean test jacocoTestReport pitest` |

---

## Related

- [quality-gates.md](./quality-gates.md) - Threshold requirements
- [../workflows/validate-coverage.md](../workflows/validate-coverage.md) - Validation workflow
