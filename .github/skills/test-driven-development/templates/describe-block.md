# Nested Test Structure Template

Organize tests by **what code does** (behavior), not by **method names**.

## ❌ Bad: Method-Based Organization

```java
class UserServiceTest {

    @Test
    void getUserById_returnsUser() { ... }

    @Test
    void getUserById_throwsWhenNotFound() { ... }

    @Test
    void createUser_savesUser() { ... }

    @Test
    void createUser_rejectsDuplicate() { ... }

    @Test
    void deleteUser_removesUser() { ... }
}
```

**Problems:**

- Tests mirror code structure, not behavior
- Hard to see all behaviors for a scenario
- Encourages one-test-per-method thinking

## ✅ Good: Behavior-Based Organization

```java
class UserServiceTest {

    @Nested
    class WhenLookingUpUser {

        @Test
        void returnsUserWhenFound() { ... }

        @Test
        void throwsNotFoundWhenMissing() { ... }

        @Test
        void logsAccessTime() { ... }
    }

    @Nested
    class WhenCreatingUser {

        @Test
        void savesNewUser() { ... }

        @Test
        void assignsDefaultSettings() { ... }

        @Test
        void rejectsDuplicateEmail() { ... }

        @Test
        void sendsWelcomeEmail() { ... }
    }

    @Nested
    class WhenDeletingUser {

        @Test
        void removesUserRecord() { ... }

        @Test
        void preservesAuditHistory() { ... }

        @Test
        void notifiesAdmins() { ... }
    }
}
```

**Benefits:**

- Groups related behaviors together
- Documents what the system does
- Easy to find all tests for a scenario

## Nested Describe Pattern

Use nesting for sub-behaviors:

```java
class OrderServiceTest {

    @Nested
    class Checkout {

        @Nested
        class WhenCartHasItems {

            @Test
            void createsOrder() { ... }

            @Test
            void calculatesTotal() { ... }

            @Test
            void appliesDiscounts() { ... }
        }

        @Nested
        class WhenCartIsEmpty {

            @Test
            void throwsEmptyCartException() { ... }
        }

        @Nested
        class WhenPaymentFails {

            @Test
            void doesNotCreateOrder() { ... }

            @Test
            void notifiesCustomer() { ... }
        }
    }

    @Nested
    class Shipping {

        @Nested
        class WhenCalculatingCost {

            @Test
            void usesWeightBasedPricing() { ... }

            @Test
            void appliesFreeShippingThreshold() { ... }
        }
    }
}
```

## Scenario Template

```java
class [Feature/System]Test {

    @Nested
    class [BehaviorCategory] {

        @Nested
        class When[Condition/Scenario] {

            @Test
            void [expectedOutcomeInBusinessTerms]() {
                // Arrange - setup
                // Act - execute
                // Assert - verify
            }
        }
    }
}
```

## Guidelines

- **Top-level class**: System/service under test
- **First @Nested level**: Behavior category or feature area
- **Second @Nested level**: Specific scenario (often "When X")
- **@Test methods**: Individual assertions

Keep nesting ≤3 levels to maintain readability.

## Naming Conventions

| Level | Pattern | Example |
|-------|---------|---------|
| Class | `[System]Test` | `OrderServiceTest` |
| Nested (behavior) | `[Feature]` or `When[Action]` | `Checkout`, `WhenCreatingOrder` |
| Nested (scenario) | `When[Condition]` | `WhenCartIsEmpty` |
| Test method | `[expectedBehavior]` | `throwsEmptyCartException` |
