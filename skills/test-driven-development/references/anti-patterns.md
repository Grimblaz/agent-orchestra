# Test Anti-Patterns Reference

Based on common "vibe coding" mistakes when writing tests with AI assistance.

## Core Principle

> **Tests should describe WHAT the code does, not HOW it does it.**

Anti-patterns make tests brittle, misleading, or useless for catching bugs.

## ❌ Testing Private Methods

**Problem:** Using reflection to test private methods

```java
// ❌ BAD: Testing private method via reflection
@Test
void testCalculateDiscount() throws Exception {
    Method method = OrderService.class.getDeclaredMethod("calculateDiscount", BigDecimal.class);
    method.setAccessible(true);

    BigDecimal result = (BigDecimal) method.invoke(service, new BigDecimal("100"));

    assertThat(result).isEqualTo(new BigDecimal("10"));
}
```

**Why it's bad:**

- Couples tests to implementation details
- Breaks when you refactor (rename method, change visibility)
- Tests internal mechanics, not observable behavior

**Fix:** Test through public interface

```java
// ✅ GOOD: Test the public behavior
@Test
void orderWithPromoCodeHasReducedTotal() {
    Order order = new Order(items, promoCode);

    BigDecimal total = orderService.calculateTotal(order);

    assertThat(total).isLessThan(order.getSubtotal());
}
```

## ❌ Testing Implementation Details

**Problem:** Asserting on HOW something works

```java
// ❌ BAD: Testing implementation
@Test
void getUserCallsRepository() {
    service.getUserById("123");

    verify(repository, times(1)).findById("123");
}
```

**Why it's bad:**

- Breaks if you add caching (now calls 0 times)
- Breaks if you batch requests
- Doesn't verify the actual behavior

**Fix:** Test the outcome

```java
// ✅ GOOD: Test the result
@Test
void getUserReturnsMatchingUser() {
    User expected = new User("123", "test@example.com");
    when(repository.findById("123")).thenReturn(Optional.of(expected));

    User result = service.getUserById("123");

    assertThat(result).isEqualTo(expected);
}
```

## ❌ Excessive Edge Case Testing

**Problem:** Testing impossible or irrelevant scenarios

```java
// ❌ BAD: Testing for impossible input
@Test
void handlesNullUserId() {
    // If null IDs can't happen in your system, don't test for them
    assertThrows(NullPointerException.class, () -> service.getUserById(null));
}

@Test
void handlesEmptyUserId() {
    // Is empty string a realistic input?
}

@Test
void handlesWhitespaceUserId() {
    // Does this scenario ever occur?
}
```

**Why it's bad:**

- Tests for scenarios that never happen
- Bloats test suite without adding value
- May encourage defensive code that hides bugs

**Fix:** Test realistic scenarios

```java
// ✅ GOOD: Test real scenarios
@Test
void throwsNotFoundForUnknownUser() {
    when(repository.findById("unknown")).thenReturn(Optional.empty());

    assertThrows(UserNotFoundException.class, () -> service.getUserById("unknown"));
}
```

## ❌ Testing Formulas Instead of Rules

**Problem:** Testing exact arithmetic

```java
// ❌ BAD: Testing the formula
@Test
void healthIs10TimesVitality() {
    Character character = new Character(15);

    assertThat(character.getMaxHealth()).isEqualTo(150);
}
```

**Why it's bad:**

- Breaks when you tweak the formula
- Doesn't communicate the game rule
- Encourages copy-pasting formula into test

**Fix:** Test the rule

```java
// ✅ GOOD: Test the behavior rule
@Test
void higherVitalityGivesMoreHealth() {
    Character lowVit = new Character(10);
    Character highVit = new Character(20);

    assertThat(highVit.getMaxHealth()).isGreaterThan(lowVit.getMaxHealth());
}

// Use parameterized tests for formula verification (config, not logic)
@ParameterizedTest
@CsvSource({"10, 100", "20, 200", "30, 300"})
void healthScalesWithVitality(int vitality, int expectedHealth) {
    // This is configuration testing, kept separate from behavior tests
}
```

## ❌ Testing Framework Functionality

**Problem:** Testing that libraries work

```java
// ❌ BAD: Testing Spring's @Autowired
@Test
void serviceIsInjected() {
    assertThat(userService).isNotNull();
}

// ❌ BAD: Testing JPA works
@Test
void canSaveAndRetrieve() {
    repository.save(user);
    User found = repository.findById(user.getId());
    assertThat(found).isEqualTo(user);
}
```

**Why it's bad:**

- Tests the framework, not your code
- Framework already has its own tests
- Adds no value to your test suite

**Fix:** Test your business logic

```java
// ✅ GOOD: Test your domain rules
@Test
void newUserStartsAtLevelOne() {
    User user = userService.createUser("test@example.com");

    assertThat(user.getLevel()).isEqualTo(1);
}
```

## ❌ One Test Per Method

**Problem:** Mirroring code structure in tests

```java
// ❌ BAD: One test per method
class UserServiceTest {
    @Test void testGetUserById() { ... }
    @Test void testCreateUser() { ... }
    @Test void testUpdateUser() { ... }
    @Test void testDeleteUser() { ... }
}
```

**Why it's bad:**

- Doesn't capture behavior variations
- Missing error cases, edge cases
- Tests become a checklist, not documentation

**Fix:** Organize by behavior

```java
// ✅ GOOD: Organize by scenario
class UserServiceTest {
    @Nested class WhenCreatingUser {
        @Test void assignsDefaultLevel() { ... }
        @Test void sendsWelcomeEmail() { ... }
        @Test void rejectsDuplicateEmail() { ... }
    }

    @Nested class WhenDeletingUser {
        @Test void removesUserData() { ... }
        @Test void preservesOrderHistory() { ... }
        @Test void notifiesAdmins() { ... }
    }
}
```

## Quality Gate Enforcement

These anti-patterns are caught by:

| Anti-Pattern     | Enforcement                         |
| ---------------- | ----------------------------------- |
| Weak assertions  | Mutation testing (≥80%)             |
| Missing coverage | JaCoCo coverage (≥80%)              |
| Brittle tests    | Frequent test failures on refactor  |

## Related

- [test-patterns.md](./test-patterns.md) - Patterns to follow
- [quality-gates.md](./quality-gates.md) - Enforcement thresholds
