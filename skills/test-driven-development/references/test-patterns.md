# Test Patterns Reference

## AAA Pattern (Arrange-Act-Assert)

Every test should follow the AAA structure:

```java
@Test
void userLevelIncrementsOnLevelUp() {
    // Arrange - Set up test data
    User user = new User("test-user", 1);
    LevelingService service = new LevelingService();

    // Act - Execute the behavior
    service.levelUp(user);

    // Assert - Verify the outcome
    assertThat(user.getLevel()).isEqualTo(2);
}
```

**Benefits:**

- Clear test structure
- Easy to read and maintain
- Forces single responsibility per test

## Parameterized Tests

Use `@ParameterizedTest` for testing multiple inputs:

```java
@ParameterizedTest
@CsvSource({
    "1, 100, 2",      // Level 1 needs 100 XP
    "5, 500, 6",      // Level 5 needs 500 XP
    "10, 1000, 11"    // Level 10 needs 1000 XP
})
void levelsUpWhenXpThresholdReached(int startLevel, int xpGained, int expectedLevel) {
    User user = new User("test", startLevel);

    user.gainXp(xpGained);

    assertThat(user.getLevel()).isEqualTo(expectedLevel);
}
```

**Use cases:**

- Testing boundary conditions
- Validating formulas across ranges
- Reducing test duplication

## Test Data Builders

Create builders for complex test objects:

```java
// src/test/java/com/example/builders/UserBuilder.java
public class UserBuilder {
    private String id = "test-user";
    private String email = "test@example.com";
    private int level = 1;
    private int xp = 0;

    public static UserBuilder aUser() {
        return new UserBuilder();
    }

    public UserBuilder withId(String id) {
        this.id = id;
        return this;
    }

    public UserBuilder withLevel(int level) {
        this.level = level;
        return this;
    }

    public UserBuilder withXp(int xp) {
        this.xp = xp;
        return this;
    }

    public User build() {
        return new User(id, email, level, xp);
    }
}

// Usage in tests
@Test
void experiencedUserGetsBonus() {
    User user = aUser()
        .withLevel(10)
        .withXp(5000)
        .build();

    assertThat(user.getBonusMultiplier()).isGreaterThan(1.0);
}
```

## Behavior-Focused Testing

Test **what** code does, not **how** it does it:

```java
// ✅ GOOD: Tests behavior
@Test
void higherVitalityIncreasesMaxHealth() {
    Character lowVit = new Character(10);
    Character highVit = new Character(20);

    assertThat(highVit.getMaxHealth()).isGreaterThan(lowVit.getMaxHealth());
}

// ❌ BAD: Tests implementation
@Test
void calculateHealthMultipliesVitalityByTen() {
    Character character = new Character(10);

    assertThat(character.getMaxHealth()).isEqualTo(100); // Brittle!
}
```

## Integration Tests Over Micro-Units

Prefer testing meaningful behaviors over individual methods:

```java
// ✅ GOOD: Tests user scenario
@Test
void userCanCompleteCheckout() {
    Cart cart = new Cart();
    cart.addItem(product, 2);

    Order order = checkoutService.checkout(cart, paymentInfo);

    assertThat(order.getStatus()).isEqualTo(OrderStatus.CONFIRMED);
    assertThat(order.getItems()).hasSize(1);
    assertThat(order.getTotal()).isEqualTo(product.getPrice().multiply(2));
}

// ❌ BAD: Tests internal method
@Test
void calculateSubtotalSumsItemPrices() {
    // Testing private calculation logic
}
```

## Test Organization

Organize tests by **behavior**, not method name:

```java
// ✅ GOOD: Behavior-based organization
class UserServiceTest {

    @Nested
    class WhenUserExists {
        @Test
        void returnsUser() { ... }

        @Test
        void logsAccessTime() { ... }
    }

    @Nested
    class WhenUserNotFound {
        @Test
        void throwsNotFoundException() { ... }

        @Test
        void doesNotLogAccess() { ... }
    }
}

// ❌ BAD: Method-based organization
class UserServiceTest {
    @Test
    void getUserById_success() { ... }

    @Test
    void getUserById_notFound() { ... }

    @Test
    void getUserById_logsAccess() { ... }
}
```

## Related

- [anti-patterns.md](./anti-patterns.md) - Patterns to avoid
- [../templates/test-file.md](../templates/test-file.md) - Test file template
- [../templates/describe-block.md](../templates/describe-block.md) - Nested test structure
