# Playwright E2E Patterns

Use these patterns to keep browser tests readable, stable, and maintainable.

## 1) Test Behavior, Not Internals

- Assert visible outcomes a user can observe
- Avoid asserting framework internals, transient DOM structure, or private API details
- Prefer flows that cover meaningful business behavior end-to-end

## 2) Prefer Accessible Locators

Recommended order:

1. `page.getByRole()`
2. `page.getByLabel()` / `page.getByPlaceholder()`
3. `page.getByTestId()`
4. CSS selectors (fallback)

Example:

```ts
await page.getByRole('button', { name: '[CUSTOMIZE] Submit' }).click();
await expect(page.getByRole('status')).toContainText('[CUSTOMIZE] Saved');
```

## 3) Use Auto-Wait + Explicit Expectations

- Avoid `waitForTimeout` except as a last-resort debug aid
- Wait for stable UI state with `expect(...).toBeVisible()` or `toHaveText()`
- Use route/network expectations only when validating network-driven behavior

## 4) Isolate Test State

- Each test creates/owns its own data when practical
- Use deterministic fixtures and teardown hooks
- Do not depend on test order

Common strategies:

- Seed via API before test run
- Create data through UI for high-value happy paths
- Use `[CUSTOMIZE]` cleanup endpoint/script where available

## 5) Keep Auth Fast and Deterministic

- Prefer reusable authenticated state (`storageState`) for most tests
- Reserve full login UI flow for a smaller smoke subset
- Rotate or reset test accounts with `[CUSTOMIZE]` project process

## 6) Handle Flakiness Systematically

When a test flakes:

1. Reproduce with retries disabled
2. Capture trace/video/screenshot artifacts
3. Check selector stability and async timing assumptions
4. Remove shared-state and clock/network nondeterminism
5. Add a targeted assertion for the true readiness signal

## 7) Structure Tests for Clarity

- Group by feature/user journey
- One scenario per test with clear Arrange-Act-Assert flow
- Extract repeated page actions into helper functions or page objects

## 8) Minimal Anti-Patterns

- Overusing brittle CSS/XPath chains
- Hard-coded sleeps and arbitrary polling loops
- Assertions immediately after action without readiness checks
- Multi-purpose tests that fail for unrelated reasons

## 9) Debug Workflow

Useful commands:

```bash
# [CUSTOMIZE] Run a specific test file
npx playwright test [CUSTOMIZE]/checkout.spec.ts

# [CUSTOMIZE] Interactive debug
npx playwright test --debug

# [CUSTOMIZE] Open trace viewer
npx playwright show-trace [CUSTOMIZE]/trace.zip
```
