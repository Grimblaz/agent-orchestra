# Write Tests First (RED Phase)

## Overview

The RED phase is about writing a test that describes what you want the code to do—before writing any implementation. The test should fail because the code doesn't exist yet.

## Workflow Steps

### 1. Identify Behavior to Test

Ask yourself: **What should this code do?** (not how it does it)

**Good behavior descriptions:**

- "Service returns user when found by ID"
- "Validation rejects empty usernames"
- "Calculator adds two numbers correctly"

**Bad (implementation-focused):**

- "getUserById calls repository.findById"
- "validate method throws IllegalArgumentException"
- "add method returns a + b"

### 2. Write the Test

```java
// src/test/java/com/example/service/UserServiceTest.java
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.BeforeEach;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.Mockito.*;

class UserServiceTest {

    private UserRepository repository;
    private UserService service;

    @BeforeEach
    void setUp() {
        repository = mock(UserRepository.class);
        service = new UserService(repository);
    }

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
}
```

### 3. Verify Test Fails (RED)

```bash
./gradlew test --tests "UserServiceTest.returnsUserWhenFoundById"
```

**Expected:** Test fails with compilation error or assertion failure.

```text
[ERROR] UserServiceTest.java: cannot find symbol
  symbol: class UserService
```

This confirms you're in RED state—the test correctly fails.

### 4. Commit the Failing Test (Optional)

Some teams commit failing tests to document intent:

```bash
git add -A
git commit -m "test: add failing test for user lookup by ID"
```

## Checklist

- [ ] Test describes **behavior**, not implementation
- [ ] Test name uses business language
- [ ] Test follows AAA pattern (Arrange-Act-Assert)
- [ ] Test fails for the right reason (missing implementation, not wrong setup)
- [ ] No `@Disabled` or skipped tests

## Anti-Patterns to Avoid

- ❌ Writing test after implementation
- ❌ Testing private methods directly
- ❌ Asserting on implementation details (method calls, internal state)
- ❌ Writing tests that can't fail

## Next Steps

After test is RED → [make-tests-pass.md](./make-tests-pass.md) (GREEN phase)

## Related

- [../references/test-patterns.md](../references/test-patterns.md) - AAA pattern, factories
- [../references/anti-patterns.md](../references/anti-patterns.md) - What to avoid
- [../templates/test-file.md](../templates/test-file.md) - Test file structure
