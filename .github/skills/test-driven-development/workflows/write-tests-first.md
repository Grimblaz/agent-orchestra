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

### 2. Domain Peer Check

**When to complete**: If the function under test validates, parses, deserializes, or constrains an input field for which another function (new in the PR or existing in the codebase) also operates on the same field, complete this step before writing tests. Otherwise, skip to Step 3.

**Identifying the same field**: A field is "the same" when any of the following hold:

- Functions share the parameter/field **name** (e.g., both accept `seed`)
- Functions reference the same **documented concept** (e.g., plan says "game seed" for both, even if one names it `seed` and another `gameSeed`)
- One function's **output feeds the other's input** (e.g., parser output → validator input)

When uncertain, err toward checking — a quick grep is cheaper than a mismatched domain reaching CE Gate.

1. **Enumerate peers**: Grep for the field name in function signatures and parameters, scoped to source files. Include both new functions in the PR and existing functions. For concept-linked fields with different names, consult the plan or design document for shared terminology. For data-flow relationships, trace call chains to identify functions whose output becomes the input for another.

2. **Compare ranges**: For each peer, note the accepted input range. Confirm they are identical (check inclusive/exclusive bounds, signed/unsigned treatment, and type coercion behavior).

3. **Resolve or document**: If ranges differ unintentionally, resolve before writing RED tests. If intentionally different, document the rationale in the plan step or as an inline code comment near the divergent function.

> **Do not write RED tests that accept inputs a paired function rejects** — unless the difference is an intentional, documented design decision.

**Example**: Planning RED tests for `validateConfig(timeout)` which accepts `[1, 3600]`. Grep reveals existing `parseTimeoutParam(raw)` accepts `[0, MAX_SAFE_INTEGER]`. Range mismatch: validator rejects `0`, parser accepts it. → Resolve: align validator to accept `0`, or document why `0` is invalid for config but valid as a raw param.

### 3. Write the Test

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

### 4. Verify Test Fails (RED)

```bash
./gradlew test --tests "UserServiceTest.returnsUserWhenFoundById"
```

**Expected:** Test fails with compilation error or assertion failure.

```text
[ERROR] UserServiceTest.java: cannot find symbol
  symbol: class UserService
```

This confirms you're in RED state—the test correctly fails.

### 5. Commit the Failing Test (Optional)

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
- [ ] Domain Peer Check: if function shares a field with another validator, parser, deserializer, or constraining function (new or existing), input ranges confirmed identical or difference documented

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
