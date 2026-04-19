---
name: webapp-testing
description: Playwright end-to-end testing guidance for web apps, with practical patterns and setup steps. Use when creating or improving browser-based E2E coverage, test stability, and CI execution. DO NOT USE FOR: React component tests (use ui-testing), canvas game interaction (use browser-canvas-testing), TDD workflow (use test-driven-development), debugging failures (use systematic-debugging), or randomized property tests (use property-based-testing).
---

# Web App Testing Skill

## Overview

This skill provides practical Playwright E2E guidance for reliable web app testing across local and CI environments.

> **[CUSTOMIZE]** Replace sample URLs, auth flows, selectors, and command snippets with your project-specific values.

<intake>

## What do you need help with?

Choose one intent:

1. **patterns** - Test design, selectors, waits, and reliability techniques
2. **setup** - Playwright installation, config, environments, and CI basics
3. **quickstart** - Minimal path to run first E2E test

What do you want to do? _(patterns/setup/quickstart)_

</intake>

<routing>

## Response Routing

| Response   | File                                  | Purpose                                                         |
| ---------- | ------------------------------------- | --------------------------------------------------------------- |
| patterns   | `patterns.md`                         | Test-writing patterns, anti-flake practices, and debugging flow |
| setup      | `playwright-setup.md`                 | Setup steps, config model, environment strategy, and CI notes   |
| quickstart | `playwright-setup.md` → `patterns.md` | Stand up tooling first, then apply stable test patterns         |

</routing>

## Quick Principles

- Prefer user-visible assertions over implementation details
- Use robust locators (`getByRole`, `getByLabel`, `getByTestId`) before CSS/XPath
- Keep tests isolated and data-independent
- Minimize fixed sleeps; rely on Playwright auto-wait and explicit expect conditions
- Stabilize E2E by controlling auth, test data, and network behavior

## References

- `patterns.md` - Practical E2E patterns and pitfalls
- `playwright-setup.md` - Setup and environment configuration

## Gotchas

| Trigger                                                              | Gotcha                                                           | Fix                                                                                                               |
| -------------------------------------------------------------------- | ---------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------- |
| Using `div > ul > li:nth-child(3) > button` as a locator             | Breaks on any DOM restructure, even visually invisible ones      | Use `getByRole` > `getByLabel` > `getByTestId` > CSS (last resort)                                                |
| `await page.waitForTimeout(3000)` to wait for readiness              | Adds hard delay to every run; flakes on slow CI                  | Replace with `await expect(locator).toBeVisible()` using Playwright auto-wait                                     |
| Asserting immediately after an action without waiting for the result | Race condition; flakes on slow renders                           | Use Playwright's built-in auto-wait: `await expect(locator).toHaveText(...)`                                      |
| Test B passes only when test A runs first                            | Order-dependent suite fails on parallel CI runs                  | Each test creates and owns its own data; tear down on completion                                                  |
| Running full login UI flow for most tests                            | Login is not re-tested; you're paying time cost repeatedly       | Use `storageState` for authenticated tests; reserve full login UI for a small smoke subset                        |
| One test scenario covers three different features                    | A failure in one feature fails the entire test; hard to diagnose | One scenario per test; group by feature or user journey                                                           |
| Retrying a flaky test and moving on when it passes                   | Root cause unknown; intermittent issue will recur                | Repro with retries disabled; capture `--trace on` artifacts; investigate selector stability and async assumptions |
