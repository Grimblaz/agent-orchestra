# Terminal & Test Hygiene

## Purpose

Long Copilot agent sessions accumulate idle `pwsh` processes that each trigger Windows Defender
AMSI scanning, causing sustained CPU load and fan noise — even when the user is away from the
computer. The issue is model-sensitive: on the same orchestration pipeline (issue #248), GPT 5.4
reached 35+ concurrent `pwsh` processes while Sonnet 4.6 stayed at 8–10. Aggressive models issue
more `isBackground: true` terminal calls and invoke the full Pester suite repeatedly rather than
targeting specific test files.

The fix must be **model-agnostic**: explicit guardrails in the shared agent context so that any
model follows the same lean terminal pattern.

Issue #313 extends this design with a kill-before-retry protocol and port-check diagnostic script,
addressing the within-step retry gap that the Terminal Lifecycle Protocol does not cover.

## Implemented Surface

| File | Role |
| --- | --- |
| `.github/copilot-instructions.md` | `## Terminal & Test Hygiene` section — primary guardrail location |
| `CONTRIBUTING.md` | Advisory VS Code setting recommendation (D5) |
| `.github/agents/Code-Conductor.agent.md` | `### Terminal Lifecycle Protocol` section (TD1–TD5) |
| `.github/scripts/lib/quick-validate-core.ps1` | Quick-validate library — `Invoke-QuickValidate` (TD6) |
| `.github/scripts/quick-validate.ps1` | Quick-validate CLI wrapper (TD6) |
| `.github/scripts/Tests/quick-validate.Tests.ps1` | Pester tests for quick-validate (TD6) |
| `.github/skills/terminal-hygiene/scripts/check-port-core.ps1` | Port-availability check library — `Invoke-CheckPort` (TD7) |
| `.github/skills/terminal-hygiene/scripts/check-port.ps1` | Port-check CLI wrapper (TD7) |
| `.github/scripts/Tests/check-port.Tests.ps1` | Pester tests for check-port (TD7) |

## Design Decisions

### D1 — Guardrail location: `copilot-instructions.md`

The guardrails live in `copilot-instructions.md` (frontmatter `applyTo: "**"`), which is loaded
automatically by every agent including subagents. This is the only location that reaches all
execution contexts.

The former shared instruction-file delivery path was considered but rejected — the current `safe-operations` skill reaches this guidance without relying on a shared instruction path.
A Code-Conductor-only section was considered but rejected — subagents bypass it. The new section
explicitly **supplements** (does not replace) agent-specific terminal guidance such as
Code-Conductor's Terminal Non-Interactive Guardrails.

### D2 — Pester scope: targeted during iteration, full suite at Tier 1 gate

During inner-loop iteration on a specific test, use targeted invocation:

```powershell
Invoke-Pester 'path/to/specific.Tests.ps1' -Output Minimal
```

The full-suite command (`Invoke-Pester .github/scripts/Tests/ -Output Minimal`) remains the
standard Tier 1 validation gate at **step boundaries** — not during inner-loop iteration.

A Pester concurrency cap was considered but rejected: the targeted-only rule handles the 95% case
with lower complexity (see R3).

### D3 — `isBackground` default for validation commands

Use `isBackground: false` for Pester, PSScriptAnalyzer, `markdownlint-cli2`, structural checks,
and any command expected to complete in under 60 seconds. `isBackground: false` reuses the shared
terminal; `isBackground: true` spawns a new persistent `pwsh` process that stays alive after the
command finishes.

Reserve `isBackground: true` for dev servers and watch-mode builds.

**Override**: the process-troubleshooting skill's stall-diagnosis guidance takes precedence when
diagnosing a terminal stall.

### D5 — Advisory VS Code setting in `CONTRIBUTING.md`

`CONTRIBUTING.md` recommends `terminal.integrated.enablePersistentSessions: false` in VS Code user
settings. This prevents VS Code from restoring terminal processes after a window restart or reload,
reducing background accumulation between sessions. This is advisory — not enforced — and lives in
`CONTRIBUTING.md` because it crosses into workstation configuration.

### D6 — No terminal/subagent batching in the same parallel tool-call set

`run_in_terminal` and subagent dispatch (`runSubagent` or agent-tool dispatch) must not appear in
the same parallel tool-call set. Sequential use — terminal validation then subagent dispatch, or
vice versa — is fine. Parallel subagent dispatch (e.g., 3-pass Code-Critic prosecution) remains
allowed; the restriction applies to terminal commands alongside subagents only.

### D7 — Final-gate full-suite Pester must use `isBackground: true` (live-refresh only)

The full Pester suite (`Invoke-Pester .github/scripts/Tests/ -Output Minimal`) includes tests tagged `requires-gh`
that previously made live GitHub API calls and could take 10–20 minutes, violating D3's "under 60
seconds" assumption.

**Gap**: D3's `isBackground: false` default does not carve out long-running Pester suites.

**Root cause evidence**: issues #252 (terminal process accumulation) and #259 (session stall
caused by running the full suite synchronously at the Tier 1 gate).

**Updated behavior (issue #271)**: `aggregate-review-scores.Tests.ps1` now defaults to
**fixture mode** (D8), eliminating all live API calls from the standard full-suite run. The full
suite completes in under 60 seconds in fixture mode; use `isBackground: false` as normal.

The `isBackground: true` exception now applies only to **live-refresh runs** (`PESTER_LIVE_GH=1`):
run with `isBackground: true` and poll with `get_terminal_output` to read results. Pester 5
routes pass/fail output to the terminal buffer, not to PowerShell streams — `*>` file
redirection only captures advisory output (e.g., `Write-Warning`). The PS prompt appearing on
the final line of `get_terminal_output` signals that the process has exited.
Do not use `await_terminal` for this call. Targeted single-file Pester invocations (D2) are
unaffected and remain `isBackground: false`.

### D8 — Fixture-backed test mode for `aggregate-review-scores.Tests.ps1`

Issue #271 added static JSON fixtures and a fixture-mode detection block to
`aggregate-review-scores.Tests.ps1` so that all 49 `requires-gh` tests run without live GitHub
API calls.

**Fixture files** (committed to the repo):

| File | Content |
| --- | --- |
| `.github/scripts/Tests/fixtures/github-docs-window.json` | 10-PR merged window from `github/docs`; full PR bodies |
| `.github/scripts/Tests/fixtures/copilot-orchestra-nonmetrics.json` | Non-metrics PRs from `Grimblaz/copilot-orchestra`; bodies stripped to `"(non-metrics)"` |

**Toggle** (`PESTER_LIVE_GH` env var):

| Value | Behavior |
| --- | --- |
| Not set (default) | Fixture mode — fixtures must be present; all `requires-gh` tests pass offline |
| `1` | Live mode — real `gh` CLI calls; auto-refreshes fixture files from live data |

**3-way fallback** (fixture mode detection block in `BeforeAll`):

1. Fixture files present + `PESTER_LIVE_GH` not `'1'` → fixture mode (fast, offline)
2. No fixtures + `gh` available → live mode (`PESTER_LIVE_GH=1` also enables auto-refresh)
3. No fixtures + no `gh` → skip mode (`requires-gh` tests skipped with a warning)

**`mergedAt` normalization**: at fixture-load time, all timestamps are shifted uniformly so that the
most-recent PR is ~7 days old. This keeps time-decay weights (`exp(-0.023 × days)`) stable
regardless of fixture age and prevents test failures as fixtures grow older.

**Staleness warning**: if the raw most-recent `mergedAt` is >30 days old, the test runner emits a
`Write-Warning` recommending a live-refresh run.

**Auto-refresh** (`PESTER_LIVE_GH=1`): after the live bootstrap completes, the test runner writes
fresher fixture files. A SHA-256 hash check prevents no-op git diffs when data has not changed.

**Pattern for future test authors**: new `requires-gh` tests that call `InvokeAggregate` benefit
from fixture mode automatically. Direct `& gh` calls added to BeforeAll blocks must follow the
either-branch pattern:

```powershell
if ($script:FixtureMode) {
    $script:MyVar = @($script:FixtureOrchNormalized | ForEach-Object { [int]$_.number })
} else {
    $script:MyVar = @(& gh pr list --repo ... --json number ... | ConvertFrom-Json | ...)
}
```

See the `prosecution_depth` BeforeAll block for the canonical reference implementation.

**Post-merge fixture refresh**: after merging a PR that introduces new test data patterns, run
`$env:PESTER_LIVE_GH = '1'; Invoke-Pester '.github/scripts/Tests/aggregate-review-scores.Tests.ps1' -Output Minimal; Remove-Item Env:\PESTER_LIVE_GH`
then commit the updated fixture files. This is a manual step (no CI automation) done when
test assumptions about live PR data may have drifted.

### D9 — Kill-before-retry protocol in `copilot-instructions.md`

Issue #313 added a `### Terminal Retry Hygiene` subsection after `### Terminal Cleanup` in
`copilot-instructions.md`. The 5-step protocol (Record → Kill → Log → Check port → Start)
targets the within-step retry gap that the Terminal Lifecycle Protocol (#294) doesn't cover.
Kill-before-retry and Terminal Cleanup are complementary, non-overlapping: kill-before-retry
acts immediately before a retry within the same step; Terminal Cleanup acts at step boundaries.

### D10 — Port-check diagnostic script (`check-port.ps1`)

A new script following the Script Library Convention (lib + wrapper + Pester tests). Uses
`TcpListener` loopback bind to detect port availability and enriches with
`Get-NetTCPConnection` on Windows (guarded by cmdlet availability check). Returns JSON
`{InUse, Pid, ProcessName}`. Diagnostic-only and non-blocking — agents proceed with retry
regardless of output. Private helpers use `CP` prefix per naming convention.

### D11 — Updated `kill_terminal` availability note

The `kill_terminal` availability note in Code-Conductor's Terminal Lifecycle Protocol was updated
from "not currently in the VS Code deferred tools inventory" to "is a deferred tool — load via
`tool_search_tool_regex`". Forward-compatible: agents try to load the tool and degrade to
preserve-all when unavailable (version regression or restricted tool surface). The degradation
behavior specification is preserved.

## Rejected Alternatives

### R1 — Extend `session-cleanup-detector.ps1` with a `pwsh` process count check

Flagged across all three adversarial design review passes. Four disqualifying problems:

- **Temporal misalignment**: detector runs at session start; process accumulation happens
  mid-session
- **Unscoped signal**: cannot distinguish Copilot-spawned `pwsh` from user-owned processes
- **Dangerous cleanup**: killing live `pwsh` processes is an irreversible side effect
- **Breaks detector cohesion**: the existing detector is repo-scoped and deterministic; a
  process-count check introduces workstation-scoped and non-deterministic behavior

### R2 — Windows Defender folder-exclusion advice in `CONTRIBUTING.md`

Rejected. Advising users to create exclusions in Windows Defender crosses from project convention
into workstation security policy. That boundary belongs to the user and their organization.

### R3 — Pester concurrency cap (one invocation at a time)

Not adopted. The targeted-scope rule (D2) eliminates the accumulation problem for the 95% case. A
concurrency cap adds marginal benefit and extra metacognitive overhead for agents that are already
operating correctly.

## Scope Boundaries

### In Scope

- `copilot-instructions.md` — `## Terminal & Test Hygiene` section (D1, D2, D3, D6, D7, D8) + `### Terminal Cleanup` (TD1–TD5 summary)
- `CONTRIBUTING.md` — VS Code setting recommendation (D5)
- `.github/scripts/Tests/aggregate-review-scores.Tests.ps1` — fixture-backed test mode (D8)
- `.github/scripts/Tests/fixtures/` — static fixture files (D8)
- `.github/agents/Code-Conductor.agent.md` — Terminal Lifecycle Protocol (TD1–TD5)
- `.github/scripts/lib/quick-validate-core.ps1` — consolidated quick-validate library (TD6)
- `.github/scripts/quick-validate.ps1` — CLI wrapper (TD6)
- `.github/scripts/Tests/quick-validate.Tests.ps1` — Pester tests (TD6)
- `.github/copilot-instructions.md` — `### Terminal Retry Hygiene` subsection (D9)
- `.github/skills/terminal-hygiene/scripts/check-port-core.ps1` — port-check library (D10)
- `.github/skills/terminal-hygiene/scripts/check-port.ps1` — CLI wrapper (D10)
- `.github/scripts/Tests/check-port.Tests.ps1` — Pester tests (D10)

### Explicit Non-Goals

- Agent file changes (agents inherit via `copilot-instructions.md`)
- Mechanical enforcement or concurrency limits
- Session-cleanup-detector process counting
- Windows Defender exclusion guidance

### TD1 — Terminal ID Tracking (CC in-context)

Code-Conductor tracks terminal IDs returned by its own `run_in_terminal(isBackground: true)` calls
in conversation context. No persistent file is needed — terminal IDs are window-scoped by VS Code's
tool design, so cross-window collision is impossible. On context compaction, tracked IDs are lost;
per-step cleanup (TD2) prevents dangerous buildup, and new terminals after compaction are re-tracked.

**Rejected alternatives**:

- Session memory tracking file — extra I/O on every terminal call, and subagent write-back to the
  tracking file is unreliable.
- OS-level process cleanup — cannot distinguish Copilot-spawned `pwsh` from user-owned processes;
  killing across windows is unsafe.

### TD2 — 3-Tier Cleanup Triggers

Cleanup runs at three points in the orchestration lifecycle:

1. **Post-step**: After each plan step's validation passes and before marking `✅ DONE`.
2. **Phase-boundary**: After all implementation steps complete, before entering the review cycle.
3. **Post-PR**: After PR creation, before user handoff.

**Rejected**: End-of-orchestration-only cleanup — allows 100+ terminals to accumulate across many
steps before any cleanup runs.

### TD3 — Completion Check & Safety

Before killing a terminal, CC calls `get_terminal_output` and applies a 3-state classification:

| Output state | Classification | Action |
| --- | --- | --- |
| Ends with PS prompt (`PS ...>`) | Confirmed completed | Kill |
| Ongoing activity (no PS prompt) | Active | Preserve |
| Empty, unclear, or API error | Unknown | Preserve |

Only **confirmed-completed** terminals are killed. All other states are preserved.

### TD4 — Error Tolerance

All `kill_terminal` calls are non-fatal. If a kill fails (terminal already gone, invalid ID, API
error), CC logs the failure and continues. Cleanup must never block orchestration flow.

### TD5 — Transparent Logging

After each cleanup sweep, CC logs:

```text
Terminal cleanup: killed N completed, preserved M active, K unknown/already-gone
```

### TD6 — Quick-Validate Consolidation

8+ individual structural check commands (legacy references × 4, skill frontmatter × 3, guidance
complexity, PSScriptAnalyzer) were consolidated into a single `Invoke-QuickValidate` function.
This reduces per-pass commands from ~10 to ~2, lowering shared terminal buffer overflow
probability.

**Implementation** follows the Script Library Convention:

| File | Role |
| --- | --- |
| `.github/scripts/lib/quick-validate-core.ps1` | Library — `Invoke-QuickValidate` function + internal helpers (`Test-QV*`) |
| `.github/scripts/quick-validate.ps1` | CLI wrapper — dot-sources library, calls function, exits with result code |
| `.github/scripts/Tests/quick-validate.Tests.ps1` | Pester tests |

**9 checks** consolidated into `Invoke-QuickValidate`: Plan-Architect, Janitor, Issue-Designer,
workflow-template (legacy references), SKILL-UseWhen, SKILL-DoNotUseFor, SKILL-Gotchas (skill
frontmatter), GuidanceComplexity, PSScriptAnalyzer.

### TD7 — Subagent Terminal Gap (Accepted)

Subagent-spawned background terminal IDs are not surfaced back to Code-Conductor. This gap is
accepted because subagents follow the `isBackground: false` preference (D3), minimizing background
terminal creation. The D3 enforcement is sufficient to keep subagent terminal counts low.

### TD8 — Implementation Surface

| File | Change |
| --- | --- |
| `.github/agents/Code-Conductor.agent.md` | New `### Terminal Lifecycle Protocol` section (TD1–TD5) |
| `.github/copilot-instructions.md` | New `### Terminal Cleanup` subsection + consolidated quick-validate command |
| `.github/scripts/lib/quick-validate-core.ps1` | Library — `Invoke-QuickValidate` function (TD6) |
| `.github/scripts/quick-validate.ps1` | CLI wrapper (TD6) |
| `.github/scripts/Tests/quick-validate.Tests.ps1` | Pester tests for consolidated script (TD6) |
| `Documents/Design/terminal-test-hygiene.md` | This document — TD1–TD8 design record |

## Root Cause Cascade

Copilot-orchestra sessions generate high terminal command volume (quick-validate structural checks
at every step boundary). When the shared terminal buffer overflows (~16 KB), commands appear to
stall, prompting a switch to `isBackground: true`. Each subsequent command then spawns a new
persistent terminal. At ~30+ idle terminals, shells enter CPU-spin states.

**Two-pronged mitigation**:

- **Prevention** (TD6): `Invoke-QuickValidate` consolidates 8+ commands into 1, reducing per-pass
  terminal commands from ~10 to ~2 and lowering overflow probability.
- **Cleanup** (TD1–TD5): Terminal Lifecycle Protocol kills confirmed-completed terminals at 3 phase
  boundaries, preventing accumulation even when `isBackground: true` is triggered.

## Source Of Truth

This document records the design shipped for issue #252. The implementation source of truth is the
`## Terminal & Test Hygiene` section in `.github/copilot-instructions.md` and the Developer Setup
note in `CONTRIBUTING.md`. Updated by issue #268 to add D7. Updated by issue #271 to amend D7 and
add D8 (fixture-backed test mode). Updated by issue #294 to add TD1–TD8 (Terminal Lifecycle
Protocol and quick-validate consolidation).
