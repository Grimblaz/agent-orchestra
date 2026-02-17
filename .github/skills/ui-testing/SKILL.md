---
name: ui-testing
description: Resilient React component testing strategies focusing on user behavior. Use when writing or reviewing UI tests, fixing flaky tests, or establishing testing patterns.
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
getByRole('button', { name: 'Submit' })
getByLabelText('Email address')
getByPlaceholderText('Search...')
getByText('Welcome back')
getByAltText('User avatar')
```

### 2. Semantic Queries (Acceptable)
```javascript
// Good: Semantic HTML attributes
getByTitle('Close dialog')
getByDisplayValue('current input value')
```

### 3. Test IDs (Last Resort)
```javascript
// Fallback: When no accessible option exists
getByTestId('complex-data-grid')
```

### Never Use
```javascript
// Fragile: Breaks on any refactor
container.querySelector('.btn-primary')
wrapper.find('div > span:first-child')
getByClassName('header-title')
```

## Test Structure Pattern

```javascript
describe('ComponentName', () => {
  // Group by user goal, not by method
  describe('when user [does action]', () => {
    it('should [expected outcome visible to user]', () => {
      // Arrange: Set up component state
      render(<Component {...props} />)
      
      // Act: Simulate user behavior
      await userEvent.click(getByRole('button', { name: 'Submit' }))
      
      // Assert: Check visible outcomes
      expect(getByText('Success!')).toBeInTheDocument()
    })
  })
})
```

## Common Patterns

### Testing User Input
```javascript
it('should update display when user types', async () => {
  render(<SearchBox />)
  
  const input = getByRole('searchbox')
  await userEvent.type(input, 'query')
  
  expect(input).toHaveValue('query')
})
```

### Testing Async Operations
```javascript
it('should show results after search', async () => {
  render(<SearchResults />)
  
  await userEvent.click(getByRole('button', { name: 'Search' }))
  
  // Wait for visible change, not implementation detail
  expect(await findByText('3 results found')).toBeInTheDocument()
})
```

### Testing Accessibility
```javascript
it('should be accessible', async () => {
  const { container } = render(<Component />)
  
  const results = await axe(container)
  expect(results).toHaveNoViolations()
})
```

See [testing-patterns.md](./testing-patterns.md) for more detailed patterns.

## Anti-Patterns to Avoid

| Anti-Pattern | Problem | Better Approach |
|--------------|---------|-----------------|
| Testing internal state | Breaks on refactor | Test visible outcomes |
| Snapshot overuse | Noise, false positives | Targeted assertions |
| `waitFor` with long timeout | Hides perf issues | Fix root cause |
| Testing library internals | Not your responsibility | Trust dependencies |
| `act()` warnings ignored | Async issues hidden | Fix test timing |

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
