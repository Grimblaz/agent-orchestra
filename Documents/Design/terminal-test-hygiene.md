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

## Implemented Surface

| File | Role |
| --- | --- |
| `.github/copilot-instructions.md` | New `## Terminal & Test Hygiene` section — primary guardrail location |
| `CONTRIBUTING.md` | Advisory VS Code setting recommendation (D5) |

## Design Decisions

### D1 — Guardrail location: `copilot-instructions.md`

The guardrails live in `copilot-instructions.md` (frontmatter `applyTo: "**"`), which is loaded
automatically by every agent including subagents. This is the only location that reaches all
execution contexts.

`safe-operations.instructions.md` was considered but rejected — it is not loaded by all subagents.
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

### D7 — Final-gate full-suite Pester must use `isBackground: true`

The full Pester suite (`Invoke-Pester .github/scripts/Tests/ -Output Minimal`) includes tests tagged `requires-gh`
that make live GitHub API calls and may take 10–20 minutes to complete, violating D3's "under 60
seconds" assumption.

**Gap**: D3's `isBackground: false` default does not carve out the final-gate full suite, causing
terminal stalls when the full suite is run synchronously at Tier 1 step boundaries.

**Root cause evidence**: issues #252 (terminal process accumulation) and #259 (session stall
caused by running the full suite synchronously at the Tier 1 gate).

**Fix**: Run the final-gate full suite with `isBackground: true`, redirecting all output to a file
(e.g., `Invoke-Pester .github/scripts/Tests/ -Output Minimal *> pester-results.txt`), and poll with `get_terminal_output`. After `get_terminal_output` returns a
PS prompt on its final line (indicating the process has exited), read actual test results with
`read_file('pester-results.txt')`. Do
not use `await_terminal` for this call. Targeted single-file Pester invocations (D2) are unaffected
and remain `isBackground: false`.

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

- `copilot-instructions.md` — new `## Terminal & Test Hygiene` section (D1, D2, D3, D6, D7)
- `CONTRIBUTING.md` — VS Code setting recommendation (D5)

### Explicit Non-Goals

- Agent file changes (agents inherit via `copilot-instructions.md`)
- Mechanical enforcement or concurrency limits
- Session-cleanup-detector process counting
- Windows Defender exclusion guidance

## Source Of Truth

This document records the design shipped for issue #252. The implementation source of truth is the
`## Terminal & Test Hygiene` section in `.github/copilot-instructions.md` and the Developer Setup
note in `CONTRIBUTING.md`. Updated by issue #268 to add D7.
