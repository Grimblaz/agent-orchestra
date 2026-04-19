# Refactor Safely (REFACTOR Phase)

## Overview

The REFACTOR phase improves code quality **while keeping tests green**. Tests are your safety net—they verify refactoring doesn't break behavior.

## Golden Rule

> **Never change behavior during refactoring.**
>
> If you need new behavior, go back to RED phase first.

## Workflow Steps

### 1. Identify Code Smell

Common smells to address:

| Smell         | Description                      | Refactoring             |
| ------------- | -------------------------------- | ----------------------- |
| Duplication   | Same code in multiple places     | Extract method          |
| Long method   | Method > 20 lines                | Extract smaller methods |
| Large class   | Class > 200 lines                | Extract class           |
| Magic numbers | Hardcoded values                 | Extract constants       |
| Deep nesting  | > 3 levels of indentation        | Extract conditions      |
| Feature envy  | Method uses another class's data | Move method             |

### 2. Make Small Change

**One refactoring at a time.** Don't combine multiple changes.

### 3. Run Tests

```bash
./gradlew test
```

**Expected:** All tests still pass.

### 4. Repeat

Continue making small changes, running tests after each one.

## Common Refactorings

### Extract Method

**Before:**

```java
public OrderSummary processOrder(Order order) {
    // Calculate subtotal
    BigDecimal subtotal = BigDecimal.ZERO;
    for (OrderItem item : order.getItems()) {
        subtotal = subtotal.add(item.getPrice().multiply(BigDecimal.valueOf(item.getQuantity())));
    }

    // Apply discount
    BigDecimal discount = BigDecimal.ZERO;
    if (order.hasPromoCode()) {
        discount = subtotal.multiply(order.getPromoCode().getDiscountRate());
    }

    return new OrderSummary(subtotal, discount, subtotal.subtract(discount));
}
```

**After:**

```java
public OrderSummary processOrder(Order order) {
    BigDecimal subtotal = calculateSubtotal(order);
    BigDecimal discount = calculateDiscount(order, subtotal);
    return new OrderSummary(subtotal, discount, subtotal.subtract(discount));
}

private BigDecimal calculateSubtotal(Order order) {
    return order.getItems().stream()
        .map(item -> item.getPrice().multiply(BigDecimal.valueOf(item.getQuantity())))
        .reduce(BigDecimal.ZERO, BigDecimal::add);
}

private BigDecimal calculateDiscount(Order order, BigDecimal subtotal) {
    if (!order.hasPromoCode()) {
        return BigDecimal.ZERO;
    }
    return subtotal.multiply(order.getPromoCode().getDiscountRate());
}
```

### Extract Constant

**Before:**

```java
public boolean isEligibleForDiscount(Customer customer) {
    return customer.getOrderCount() >= 10
        && customer.getTotalSpent().compareTo(new BigDecimal("500.00")) >= 0;
}
```

**After:**

```java
private static final int LOYALTY_ORDER_THRESHOLD = 10;
private static final BigDecimal LOYALTY_SPEND_THRESHOLD = new BigDecimal("500.00");

public boolean isEligibleForDiscount(Customer customer) {
    return customer.getOrderCount() >= LOYALTY_ORDER_THRESHOLD
        && customer.getTotalSpent().compareTo(LOYALTY_SPEND_THRESHOLD) >= 0;
}
```

### Replace Conditional with Polymorphism

**Before:**

```java
public BigDecimal calculateShipping(Order order) {
    switch (order.getShippingMethod()) {
        case STANDARD:
            return new BigDecimal("5.99");
        case EXPRESS:
            return new BigDecimal("12.99");
        case OVERNIGHT:
            return new BigDecimal("24.99");
        default:
            throw new IllegalArgumentException("Unknown shipping method");
    }
}
```

**After:**

```java
public interface ShippingCalculator {
    BigDecimal calculate(Order order);
}

public class StandardShipping implements ShippingCalculator {
    public BigDecimal calculate(Order order) {
        return new BigDecimal("5.99");
    }
}

// ... similar for Express and Overnight
```

## Checklist

- [ ] Tests pass before refactoring
- [ ] Made one small change
- [ ] Tests still pass
- [ ] Code is cleaner/more readable
- [ ] No behavior changes

## When to Stop

Stop refactoring when:

- Tests pass and code is clean enough
- Further changes would require new tests (behavior change)
- Time budget is exhausted
- Diminishing returns on readability improvements

## Next Steps

After refactoring:

- Run [validate-coverage.md](./validate-coverage.md) to confirm quality gates
- Commit clean code
- Ready for PR

## Related

- [../references/test-patterns.md](../references/test-patterns.md) - Keep tests behavior-focused
- [../references/anti-patterns.md](../references/anti-patterns.md) - Anti-patterns to avoid
