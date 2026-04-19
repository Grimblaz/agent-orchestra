---
name: terminal-hygiene
description: Terminal and test execution guardrails for Copilot Orchestra workflows. Use when choosing sync versus async terminal mode, scoping Pester runs, retrying background commands, or avoiding terminal and subagent batching mistakes. DO NOT USE FOR: application-level debugging root-cause analysis (use systematic-debugging) or post-merge archival workflow steps (use post-pr-review).
---

# Terminal Hygiene

Terminal and validation rules that keep workflow execution predictable.

## When to Use

- When choosing targeted versus full-suite Pester runs
- When deciding between `mode: sync` and `mode: async` / `isBackground: true`
- When validating at step boundaries without overflowing terminal state
- When retrying background terminal commands safely

## Scope

These rules supplement, not replace, any agent-specific terminal guidance such as Code-Conductor's non-interactive guardrails.

## Pester Scope

When iterating on a specific test during red-green-refactor within an implementation step, use targeted Pester:

```powershell
Invoke-Pester 'path/to/specific.Tests.ps1' -Output Minimal
```

The full-suite command in `Build & Run > Commands` remains the standard validation gate at step boundaries. Do not run the full suite during inner-loop iteration.

## `isBackground` Default

Use `isBackground: false` for Pester, PSScriptAnalyzer, `markdownlint-cli2`, structural checks, and any command expected to complete in under 60 seconds. Reserve `isBackground: true` for dev servers and watch-mode builds.

Exceptions:

- When diagnosing a terminal stall, the `process-troubleshooting` skill guidance to switch to `isBackground: true` for diagnostics takes precedence.
- Final-gate full suite in live-refresh mode (`PESTER_LIVE_GH=1`): treat as long-running, run with `isBackground: true`, and poll with `get_terminal_output`. In fixture mode, keep `isBackground: false`.

Pester 5 writes pass/fail output to the terminal buffer rather than redirected file streams, so `*>` only captures advisory output such as `Write-Warning`. Do not use `await_terminal` for the live-refresh full-suite case; the PowerShell prompt returning on the last line signals completion.

## No Terminal/Subagent Batching

Do not batch `run_in_terminal` and subagent dispatch calls in the same parallel tool-call set. Sequential use is fine. Parallel subagent dispatch remains allowed when no terminal command shares that batch.

## Terminal Cleanup

Code-Conductor manages background terminal lifecycle with its Terminal Lifecycle Protocol. At phase boundaries such as post-step, post-implementation, and post-PR, it sweeps tracked `isBackground: true` terminal IDs, kills confirmed-completed terminals, and preserves active or unknown-state ones. Cleanup is always non-fatal.

Root cause context:

- Copilot Orchestra sessions generate high terminal command volume, especially around repeated structural checks.
- When the shared terminal buffer overflows at roughly 16 KB, commands appear to stall and later commands often shift to new background terminals.
- At roughly 30 or more idle terminals, shells can enter CPU-spin states.
- The consolidated `quick-validate.ps1` reduces per-pass command count and lowers overflow risk.

Logging contract:

```text
Terminal cleanup: killed N completed, preserved M active, K unknown/already-gone
```

Subagent gap: subagent-spawned background terminals are not tracked by Code-Conductor. Subagents should follow the `isBackground: false` preference unless a documented exception applies.

## Terminal Retry Hygiene

When retrying a failed command that ran in a background terminal (`isBackground: true` or `mode: async`), use this kill-before-retry protocol:

1. Record the terminal ID returned by `run_in_terminal`.
2. Kill that terminal via `kill_terminal` using the same terminal ID, loading the tool first with `tool_search_tool_regex` if needed.
3. If `kill_terminal` fails, log it and proceed. This is non-fatal.
4. For dev servers, run `pwsh -NoProfile -NonInteractive -File .github/skills/terminal-hygiene/scripts/check-port.ps1 -Port {PORT}` before restart to verify the port was released. If the port is still in use, log the diagnostic and proceed.
5. Start the retry in a fresh terminal.

Scope notes:

- This protocol applies to within-step retries for terminals with trackable background IDs.
- Phase-boundary cleanup of accumulated terminals remains governed by Terminal Cleanup.
- Kill-before-retry and Terminal Cleanup are complementary, not substitutes. If both target the same terminal ID, the first successful kill wins and later attempts are harmless no-ops.
- Both `kill_terminal` failures and `check-port.ps1` errors are non-blocking. Degrade gracefully to retry-without-kill when necessary.

## Gotchas

| Trigger                                               | Gotcha                                                                          | Fix                                                                            |
| ----------------------------------------------------- | ------------------------------------------------------------------------------- | ------------------------------------------------------------------------------ |
| Running full Pester repeatedly during inner-loop work | Large, repetitive output increases terminal buffer pressure and slows iteration | Use targeted Pester until the step boundary, then run the full validation gate |

| Trigger                                                         | Gotcha                                                             | Fix                                                                                                |
| --------------------------------------------------------------- | ------------------------------------------------------------------ | -------------------------------------------------------------------------------------------------- |
| Retrying a failed async server without killing the old terminal | The old shell or port can stay alive and make the retry look flaky | Kill the prior terminal ID first, check the port for dev servers, then restart in a fresh terminal |
