# Make Tests Pass (GREEN Phase)

## Overview

The GREEN phase is about writing the **minimum code** to make the failing test pass. Resist the urge to add extra functionality—that comes later.

## Golden Rule

> **Write only enough code to make the test pass.**
>
> No more, no less. Additional features need their own tests first.

## Workflow Steps

### 1. Read the Failing Test

Understand exactly what the test expects:

```java
@Test
void returnsUserWhenFoundById() {
    // Arrange
    User expected = new User("123", "john@example.com");
    when(repository.findById("123")).thenReturn(Optional.of(expected));

    // Act
    User result = service.getUserById("123");

    // Assert
    assertThat(result).isEqualTo(expected);
}
```

**What's needed:**

- `UserService` class
- `getUserById(String id)` method
- Returns `User` from repository

### 2. Write Minimum Implementation

```java
// src/main/java/com/example/service/UserService.java
@Service
public class UserService {

    private final UserRepository repository;

    public UserService(UserRepository repository) {
        this.repository = repository;
    }

    public User getUserById(String id) {
        return repository.findById(id)
            .orElseThrow(() -> new UserNotFoundException(id));
    }
}
```

### 3. Run Tests (GREEN)

```bash
./gradlew test
```

**Expected:** All tests pass.

```text
[INFO] Tests run: 1, Failures: 0, Errors: 0, Skipped: 0
[INFO] BUILD SUCCESS
```

### 4. Commit the Passing Implementation

```bash
git add -A
git commit -m "feat: implement user lookup by ID"
```

## Common Pitfalls

### Over-Engineering

❌ **Bad:** Adding features not tested

```java
public User getUserById(String id) {
    // Added caching - but no test for it!
    User cached = cache.get(id);
    if (cached != null) return cached;

    User user = repository.findById(id).orElseThrow(...);
    cache.put(id, user);  // Untested behavior
    return user;
}
```

✅ **Good:** Only what the test requires

```java
public User getUserById(String id) {
    return repository.findById(id)
        .orElseThrow(() -> new UserNotFoundException(id));
}
```

### Premature Abstraction

❌ **Bad:** Creating interfaces "for flexibility"

```java
// No test requires this interface yet
public interface UserLookupStrategy {
    User lookup(String id);
}
```

✅ **Good:** Add abstractions when tests drive them

## Checklist

- [ ] Implementation makes the failing test pass
- [ ] No extra code beyond what's tested
- [ ] All existing tests still pass
- [ ] Code compiles without warnings
- [ ] Committed with descriptive message

## Next Steps

After test is GREEN:

- If code is clean → [validate-coverage.md](./validate-coverage.md) (quality gates)
- If code needs cleanup → [refactor-safely.md](./refactor-safely.md) (REFACTOR phase)

## Related

- [write-tests-first.md](./write-tests-first.md) - RED phase
- [refactor-safely.md](./refactor-safely.md) - REFACTOR phase
- [../references/test-patterns.md](../references/test-patterns.md) - Test patterns
