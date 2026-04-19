---
name: ui-testing
description: "Resilient React component testing strategies focusing on user behavior. Use when writing or reviewing component-level React tests, fixing flaky component tests, or establishing React testing patterns. DO NOT USE FOR: Playwright E2E tests (use webapp-testing), canvas game interaction (use browser-canvas-testing), TDD workflow (use test-driven-development), debugging failures (use systematic-debugging), UI component design (use frontend-design), or randomized property tests (use property-based-testing)."
---

# UI Testing Skill

Guide for creating resilient, maintainable UI component tests.

## When to Use

- Writing tests for React components
- Debugging flaky or brittle tests
- Reviewing test code
- Establishing testing patterns for a project
- Refactoring tests after UI changes

## Core Philosophy

> "Test behavior, not implementation."

Users don't care about internal state or DOM structure—they care about what they can see and do.

## Testing Priorities (Confidence vs. Cost)

```
High Confidence, Low Cost → Prioritize
├── User interactions (clicks, typing)
├── Visible content changes
├── Accessibility requirements
└── Error states

Medium Confidence, Medium Cost → Include
├── Integration with data fetching
├── Complex state transitions
└── Edge cases

Low Confidence, High Cost → Minimize
├── Implementation details
├── Internal state values
└── CSS/styling
```

## Selector Strategy (Priority Order)

### 1. Accessible Queries (Preferred)

```javascript
// Best: How users and assistive tech find elements
getByRole("button", { name: "Submit" });
getByLabelText("Email address");
getByPlaceholderText("Search...");
getByText("Welcome back");
getByAltText("User avatar");
```

### 2. Semantic Queries (Acceptable)

```javascript
// Good: Semantic HTML attributes
getByTitle("Close dialog");
getByDisplayValue("current input value");
```

### 3. Test IDs (Last Resort)

```javascript
// Fallback: When no accessible option exists
getByTestId("complex-data-grid");
```

### Never Use

```javascript
// Fragile: Breaks on any refactor
container.querySelector(".btn-primary");
wrapper.find("div > span:first-child");
getByClassName("header-title");
```

## Test Structure Pattern

```javascript
describe("ComponentName", () => {
  // Group by user goal, not by method
  describe("when user [does action]", () => {
    it("should [expected outcome visible to user]", () => {
      // Arrange: Set up component state
      render(<Component {...props} />);

      // Act: Simulate user behavior
      await userEvent.click(getByRole("button", { name: "Submit" }));

      // Assert: Check visible outcomes
      expect(getByText("Success!")).toBeInTheDocument();
    });
  });
});
```

## Common Patterns

### Testing User Input

```javascript
it("should update display when user types", async () => {
  render(<SearchBox />);

  const input = getByRole("searchbox");
  await userEvent.type(input, "query");

  expect(input).toHaveValue("query");
});
```

### Testing Async Operations

```javascript
it("should show results after search", async () => {
  render(<SearchResults />);

  await userEvent.click(getByRole("button", { name: "Search" }));

  // Wait for visible change, not implementation detail
  expect(await findByText("3 results found")).toBeInTheDocument();
});
```

### Testing Accessibility

```javascript
it("should be accessible", async () => {
  const { container } = render(<Component />);

  const results = await axe(container);
  expect(results).toHaveNoViolations();
});
```

See [testing-patterns.md](./testing-patterns.md) for more detailed patterns.

## Project Configuration

[CUSTOMIZE] Add your project's testing setup:

```javascript
// Test utilities location: [path]
// Custom render with providers: [path]
// Mock patterns: [path]
// Test data factories: [path]
```

## Debugging Flaky Tests

1. **Identify the flake**: Run test in isolation 10+ times
2. **Check async handling**: Are we waiting for the right thing?
3. **Check test isolation**: Does order matter? Shared state?
4. **Check timing**: Race conditions in component or test?
5. **Add debugging**: `screen.debug()`, `logRoles(container)`

## Gotchas

| Trigger                                                                                                    | Gotcha                                                                                                      | Fix                                                                                            |
| ---------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------- |
| Asserting on `component.state` or internal refs directly                                                   | Breaks on internal refactoring even when user-visible behavior is unchanged                                 | Assert on rendered text, visible elements, or dispatched events — not internal component state |
| Adding `expect(tree).toMatchSnapshot()` to every component test                                            | One-character internal change triggers cascading snapshot failures; reviewers approve noise without reading | Replace with targeted assertions on specific text, attributes, or DOM structure                |
| Setting `waitFor` timeout > 1000ms to make a flaky test pass                                               | Masks real performance or async timing issues; adds hard delay to the entire suite                          | Diagnose why the element isn't ready sooner; fix the underlying async handling                 |
| Writing assertions that validate a third-party library's own behavior (e.g., checking React Query fetched) | Tests validate the library, not your code; break on library version changes                                 | Trust the library; test your code's response to its outputs — not the library's own logic      |
| Suppressing or ignoring `act()` warnings in the console                                                    | Async state update issues are hidden; test results become unreliable                                        | Fix the timing: wrap state updates in `act()` or switch from `fireEvent` to `userEvent`        |
| Using `data-testid` when `getByRole` would work                                                            | Tests diverge from user accessibility model; role-based queries are more resilient                          | Follow locator priority: `getByRole` > `getByLabel` > `getByTestId` > CSS (last resort)        |
| Asserting on internal library DOM nodes (e.g., react-select internals)                                     | Tests break on library upgrade, not on your code breaking                                                   | Trust the dependency; test what the user sees and can interact with                            |
