# Playwright Setup

This guide covers a practical baseline setup for browser E2E tests.

## 1) Install and Initialize

```bash
# [CUSTOMIZE] Pick your package manager
npm install -D @playwright/test
npx playwright install
```

Optional bootstrap:

```bash
# [CUSTOMIZE] Generates starter config/tests
npx playwright codegen [CUSTOMIZE]https://localhost:3000
```

## 2) Baseline Configuration

Create or update `playwright.config.ts` with project-appropriate defaults:

- `testDir`: location of E2E tests (for example `[CUSTOMIZE]tests/e2e`)
- `use.baseURL`: application base URL (for example `[CUSTOMIZE]http://localhost:3000`)
- `retries`: small CI retry count (`[CUSTOMIZE]0-2`)
- `trace`: `on-first-retry` for actionable failure artifacts
- `workers`: parallelism tuned for local and CI stability

## 3) Environment Strategy

Recommended environments:

- **Local**: fast feedback with headed/headless toggle
- **CI**: deterministic execution with fixed browser versions
- **Preview/Staging**: smoke tests against deployed build

Use environment variables for URLs and credentials:

- `[CUSTOMIZE]E2E_BASE_URL`
- `[CUSTOMIZE]E2E_USERNAME`
- `[CUSTOMIZE]E2E_PASSWORD`

## 4) Authentication Patterns

Choose one per test scope:

- **Pre-auth storage state** for most suites (fast and stable)
- **UI login flow** for dedicated auth smoke tests
- **API-assisted auth** where product architecture permits

Store auth artifacts in a dedicated path and refresh them via setup steps.

## 5) Network and Data Control

- Seed deterministic test data before suite execution
- Mock unstable third-party endpoints where needed
- Keep a clear rule for what is mocked vs. real backend behavior
- Add `[CUSTOMIZE]` reset scripts/endpoints for reliable cleanup

## 6) CI Integration Essentials

Use CI commands similar to:

```bash
# [CUSTOMIZE] CI test command
npx playwright test

# [CUSTOMIZE] Publish HTML report/artifacts
npx playwright show-report
```

CI should preserve:

- Playwright traces
- Screenshots on failure
- Videos (when enabled)
- HTML report artifacts

## 7) First Test Checklist

- App starts and is reachable at `[CUSTOMIZE]` base URL
- One smoke test passes in local headless mode
- Same test passes in CI with artifact capture
- Failures produce trace and screenshot for debugging

## 8) Troubleshooting Quick Hits

- Timeouts: verify readiness signal, not arbitrary delay
- Selector failures: switch to role/label/testid locators
- Intermittent failures: inspect trace and isolate state dependencies
- CI-only failures: compare env vars, browser install, and worker count
