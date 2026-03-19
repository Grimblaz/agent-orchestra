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
