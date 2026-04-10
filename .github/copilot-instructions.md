---
applyTo: "**"
---

# Project: Copilot Orchestra

## Overview

Multi-agent workflow system for GitHub Copilot. Provides specialized agents, skills, instruction files, and prompt templates that orchestrate AI-assisted software development.

## Technology Stack

- **Language**: Markdown (agent definitions, skills, instructions, documentation)
- **Framework**: VS Code Custom Agents (`.agent.md` format with YAML frontmatter)
- **Build Tool**: None (no compiled code)
- **Testing**: Pester (`.github/scripts/Tests/`), plus manual verification and grep-based structural checks
- **BDD Framework (opt-in)**: Structured G/W/T scenarios with scenario ID traceability and CE Gate coverage gap detection. Consumer repos enable by adding a `## BDD Framework` section to their `copilot-instructions.md`. Template ships BDD-disabled; see `.github/skills/bdd-scenarios/SKILL.md` for authoring patterns. **Phase 2 (runner dispatch)**: add `bdd: {framework}` under the heading (recognized values: `cucumber.js`, `behave`, `jest-cucumber`, `cucumber`) to enable Gherkin file generation by Test-Writer and automated runner dispatch at CE Gate time by Code-Conductor.

## Architecture

Pipeline-based agent orchestration:

```text
@Experience-Owner → @Solution-Designer → @Issue-Planner → @Code-Conductor → PR
                                                ↓
                              Code-Smith, Test-Writer, Refactor-Specialist,
                              Doc-Keeper, Research-Agent, Process-Review,
                              Specification
(CE Gate: @Code-Conductor delegates evidence capture to @Experience-Owner)
```

- **User-facing agents** (7): Experience-Owner, Solution-Designer, Issue-Planner, Code-Conductor, Code-Critic, Code-Review-Response, UI-Iterator
- **Internal agents** (7): Called automatically by Code-Conductor as subagents (`user-invocable: false`)
- **Skills** (16): Loaded on demand by agents from `.github/skills/`
- **Instructions** (7): Shared rules loaded by agents from `.github/instructions/`

## Key Conventions

- Agent files use `.agent.md` extension with YAML frontmatter (`name`, `description`, `tools`, `handoffs`, `user-invocable`)
- Skills use `SKILL.md` with `name` and `description` frontmatter in `.github/skills/{skill-name}/`
- Instruction files use `.instructions.md` extension in `.github/instructions/`
- Design documents go in `Documents/Design/`, decision records in `Documents/Decisions/`
- No auto-commit behavior in any agent — users commit manually
- Plans are saved to session memory (`/memories/session/plan-issue-{ID}.md`), which is the same-session source of truth for implementation handoff
- Design context is cached in session memory (`/memories/session/design-issue-{ID}.md`), reused by Issue-Planner when the current snapshot is still valid and refreshed from the issue body when missing or after current-pass issue/design updates; Solution-Designer still persists design details to the issue body unconditionally during design
- VS Code auto-compacts conversation when context fills; session memory (`/memories/session/`) survives compaction within the same conversation. At D9, if the user explicitly chooses Stop / Pause / resume later, Code-Conductor persists durable GitHub handoff comments with `<!-- plan-issue-{ID} -->` / `<!-- design-issue-{ID} -->`; Continue uses session memory only
- Design content goes in the GitHub issue body (Solution-Designer outputs there)
- `Documents/Design/` files use domain-based naming (`{domain-slug}.md`) and are committed with the implementation PR by Code-Conductor (delegated to Doc-Keeper)
- CE Gate uses `ce_gate: true` plan metadata and a `[CE GATE]` step for customer-experience and design-intent verification

## Code-Critic Adversarial Review Protocol

This repo uses a **scored prosecution → defense → judge pipeline** across all review stages.

**Code review** (3× prosecution, 1× defense, 1× judge):

- 3 independent parallel Code-Critic prosecution passes (pass count is fixed; per-category perspective depth is calibration-adjusted)
- 1 Code-Critic defense pass over the merged findings ledger
- 1 Code-Review-Response judge pass with confidence scoring + score summary

**Design/plan review** (3× prosecution, 1× defense, 1× judge): full pipeline invoked by Issue-Planner or via start-issue.md. Solution-Designer runs all 3 prosecution passes but stops after prosecution (non-blocking, no defense or judge step).

**CE review**: Experience-Owner exercises scenarios and captures evidence (delegated by Code-Conductor); Code-Critic then reviews adversarially (CE prosecution → defense → judge).

**GitHub review**: proxy prosecution (Code-Critic validates/scores each GitHub comment) → defense → judge.

**Post-fix review** (after accepted fixes are applied): 1+1 prosecution (diff-scoped; follow-up pass 2 and any defense/judge/routing are conditional on pass 1 producing ≥1 finding — see R2 in Code-Conductor) — triggered by Critical/High fix or control-flow modification. Loop budget: 1. Token budget optimizations (R6 express lane, R4 batch dispatch, R5 backoff) reduce subagent call overhead — see Code-Conductor for full protocol.

**Code-Critic modes** — activated by marker in the prompt:

- _(none)_ — code prosecution (3 passes)
- `"Use design review perspectives"` — design/plan prosecution (2 passes; runs as passes 1–2 of design review)
- `"Use product-alignment perspectives"` — product-alignment prosecution (1 pass; runs as pass 3 of design review)
- `"Use defense review perspectives"` — defense
- `"Use CE review perspectives"` — CE prosecution
- `"Score and represent GitHub review"` — proxy prosecution

## Session Startup Check

At the start of every new conversation, **before responding to the user's first message**, use session memory to decide whether the automatic startup detector should run:

### Canonical Automatic Startup Guard Contract

```json
{
  "sessionStartupMarkerPath": "/memories/session/session-startup-check-complete.md",
  "checkMarkerBeforeAutomaticDetectorRun": true,
  "recordMarkerAfterFirstAutomaticStartupCheck": true,
  "recordMarkerRegardlessOfCleanupChoice": true,
  "failOpenOnSessionMemoryAccessError": true,
  "manualDetectorRunsRemainAllowed": true
}
```

### Step 1 — Check prerequisites

Resolve the root path: use `$env:COPILOT_ORCHESTRA_ROOT` if set; otherwise fall back to `$env:WORKFLOW_TEMPLATE_ROOT`. If neither is set, skip the entire check silently and continue with the user's request.

### Step 2 — Check the automatic run-once guard

Before any automatic startup detector run, check session memory for the marker at `/memories/session/session-startup-check-complete.md`. If that marker is present, skip the automatic detector run and continue silently with the user's request. If session-memory lookup, read, or other access fails, fail open and still run the detector rather than suppressing the check.

### Step 3 — Run the detector

```powershell
$copilotRoot = if ($env:COPILOT_ORCHESTRA_ROOT) { $env:COPILOT_ORCHESTRA_ROOT } else { $env:WORKFLOW_TEMPLATE_ROOT }
pwsh -NoProfile -NonInteractive -File "$copilotRoot/.github/scripts/session-cleanup-detector.ps1"
```

### Step 4 — Record the run-once marker

Record or write the session-memory marker at `/memories/session/session-startup-check-complete.md` after the first automatic startup check runs so later agent hops in the same conversation skip the automatic detector run. Record the marker regardless of whether cleanup is needed and regardless of whether the user later confirms, declines, or skips cleanup. If session-memory write or other access fails, fail open: continue with the detector result you already obtained, and allow later automatic checks rather than risking a missed cleanup warning.

### Step 5 — Parse output

- Output is `{}` → continue silently, no prompt
- Output contains `hookSpecificOutput` → stale state found; proceed to Step 6

### Step 6 — Prompt the user

Present the `additionalContext` field from the output to the user using `#tool:vscode/askQuestions` with two options: "Yes — run cleanup" and "No — skip for now".

### Step 7 — Run cleanup (only if confirmed)

Execute the PowerShell code block from `additionalContext` in the terminal. Report what was cleaned up when complete.

### Step 8 — Continue with the user's request

Continue with the user's original request regardless of whether cleanup was run, skipped, or declined. This automatic run-once guard applies only to the startup path; explicit or manual detector runs still remain available after the automatic guard fires.

> **Silent skip conditions**: Skip the entire check when neither `$env:COPILOT_ORCHESTRA_ROOT` nor `$env:WORKFLOW_TEMPLATE_ROOT` is set, `pwsh` is not available, or the script produces non-JSON output. See `.github/instructions/session-startup.instructions.md` for full edge case details.

## First-Contact Provenance Gate

When a user-invocable agent receives a request referencing an existing GitHub issue, evaluate whether the issue framing has been validated in the current session before executing.

### Step 1 — Extract issue ID

Parse the user's request for a GitHub issue reference (`#N`, `issue N`, etc.). If no issue ID is determinable, skip the entire gate silently and continue with the user's request.

### Step 2 — Check warm-handoff markers

Check session memory for `plan-issue-{ID}` or `design-issue-{ID}` markers for this issue. Also check GitHub issue comments (via `mcp_github_issue_read` with `method: get_comments`) for `<!-- experience-owner-complete-{ID} -->` or `<!-- design-phase-complete-{ID} -->`. If any are found in either location, the issue framing was already validated — skip the gate silently.

### Step 3 — Check prior assessment marker

Use `mcp_github_issue_read` with `method: get_comments` to check for `<!-- first-contact-assessed-{ID} -->` in the issue's comments. Also check session memory at `/memories/session/first-contact-assessed-{ID}.md` for a prior assessment marker. If found in either location, skip the gate silently (previously assessed). If MCP tools are unavailable or the API call fails, fail open — skip the GitHub marker check and proceed to Step 4.

### Step 4 — Self-filtering

Skip the gate silently for agents with `user-invocable: false` in their frontmatter. Subagents dispatched by Code-Conductor already operate within an assessed session context.

### Step 5 — Run assessment

Load `.github/instructions/provenance-gate.instructions.md` for the full three-question assessment protocol (root cause vs. symptom, mechanism fitness, scope accuracy). If the instructions file is absent (plugin distribution), apply a minimal inline assessment: read the issue body, verify the stated root cause is specific and traceable, and present the developer gate via `#tool:vscode/askQuestions`.

### Step 6 — Record marker

After the developer responds (any option except 'Needs rework — stop here'), post `<!-- first-contact-assessed-{ID} -->` as a GitHub issue comment. If posting fails, record the assessment in session memory at `/memories/session/first-contact-assessed-{ID}.md` instead and proceed. In multi-issue bundles, the gate fires per unique issue ID.

> **See** `.github/instructions/provenance-gate.instructions.md` for the full assessment protocol, edge cases, and known limitations.

## Build & Run

No build step. This is a configuration/documentation template.

### Commands

```powershell
# Run PowerShell script test suite (Pester)
pwsh -NoProfile -NonInteractive -Command "Invoke-Pester .github/scripts/Tests/ -Output Minimal"
# Final-gate full suite: see Terminal & Test Hygiene > `isBackground` Default exception (final-gate full suite). In fixture mode (default), isBackground: false is fine. For live-refresh runs (PESTER_LIVE_GH=1), use isBackground: true + poll with `get_terminal_output` to read results (Pester 5 sends pass/fail output to the terminal buffer, not to file streams — `*>` redirection only captures advisory output such as `Write-Warning`).

# Validate structural checks (broken references, skill frontmatter, complexity, lint)
pwsh -NoProfile -NonInteractive -File .github/scripts/quick-validate.ps1

# Check agent count
(Get-ChildItem .github/agents/*.agent.md).Count  # should be 14
```

### Script Library Convention

Production scripts under `.github/scripts/` are split into a `lib/{name}-core.ps1` library (containing the logic as an `Invoke-*` function) and a thin CLI wrapper that dot-sources the library and calls the function. Tests dot-source `lib/` files directly and call the function in-process, avoiding per-test `pwsh` child process spawning. Private helpers inside a library embed a short uppercase prefix in the noun segment (`NW`, `WCE`, `SCD`) to avoid name collisions across dot-sourced files (e.g., `Test-NWAllowlistedPath`, `Test-WCEHasProperty`, `Get-SCDDefaultBranch`).

```powershell
# Example: call aggregate-review-scores logic in-process
. .github/scripts/lib/aggregate-review-scores-core.ps1
Invoke-AggregateReviewScores -Repo owner/name
# Example: with mock gh CLI for tests (no live API calls)
# Invoke-AggregateReviewScores -Repo owner/name -GhCliPath $mockGhScript
```

## Quick-validate (used by agents before every PR)

After editing any `.md` files, run the Markdown auto-formatter before committing:

```powershell
markdownlint-cli2 --fix "**/*.md"
```

Then run the structural checks:

```powershell
pwsh -NoProfile -NonInteractive -File .github/scripts/quick-validate.ps1
```

## Terminal & Test Hygiene

> These rules supplement (do not replace) any agent-specific terminal guidance (e.g., Code-Conductor's Terminal Non-Interactive Guardrails).

### Pester Scope

When iterating on a specific test during red-green-refactor **within** an implementation step, use targeted Pester:

```powershell
Invoke-Pester 'path/to/specific.Tests.ps1' -Output Minimal
```

The full-suite command in **Build & Run > Commands** (above) remains the standard validation gate at **step boundaries** (Tier 1). Do not run the full suite during inner-loop iteration.

### `isBackground` Default

Use `isBackground: false` for Pester, PSScriptAnalyzer, `markdownlint-cli2`, structural checks, and any command expected to complete in under 60 seconds. Reserve `isBackground: true` for dev servers and watch-mode builds.

> **Exception**: when diagnosing a terminal stall, the process-troubleshooting skill's guidance to switch to `isBackground: true` for diagnostics takes precedence.
> **Exception — final-gate full suite**: In fixture mode (default — `PESTER_LIVE_GH` not set), `aggregate-review-scores.Tests.ps1` replaces all live API calls with static fixtures and the full suite completes in under 60 seconds; use `isBackground: false` as normal. The exception applies only to **live-refresh runs** (`PESTER_LIVE_GH=1`): treat that as a long-running command and run with `isBackground: true` and poll with `get_terminal_output` to read results (Pester 5 sends pass/fail output to the terminal buffer, not to file streams — `*>` redirection only captures advisory output such as `Write-Warning`). Do not use `await_terminal` for this call. The PS prompt appearing on the final line of the `get_terminal_output` response signals completion.

### No Terminal/Subagent Batching

Do not batch `run_in_terminal` and subagent dispatch calls (`runSubagent` or agent-tool dispatch) in the same parallel tool-call set. Sequential use (terminal validation → then subagent dispatch, or vice versa) is fine. Parallel subagent dispatch (e.g., 3 Code-Critic prosecution passes) remains allowed.

### Terminal Cleanup

Code-Conductor manages background terminal lifecycle via its Terminal Lifecycle Protocol (defined in the Code-Conductor agent). At phase boundaries (post-step, post-implementation, post-PR), CC sweeps tracked `isBackground: true` terminal IDs — killing confirmed-completed terminals and preserving active or unknown-state ones. Cleanup is always non-fatal.

**Root cause context**: Copilot-orchestra sessions generate high terminal command volume (quick-validate structural checks at every step boundary). When the shared terminal buffer overflows (~16 KB), commands appear to stall, prompting a switch to `isBackground: true` — each subsequent command then spawns a new persistent terminal. At ~30+ idle terminals, shells enter CPU-spin states. The consolidated `quick-validate.ps1` script reduces per-pass commands from ~10 to ~2, lowering overflow probability. The Terminal Lifecycle Protocol catches any terminals that do accumulate.

**Logging**: After each cleanup sweep, CC logs: `"Terminal cleanup: killed N completed, preserved M active, K unknown/already-gone"`.

**Subagent gap**: Subagent-spawned background terminals are not tracked by CC. Subagents follow the `isBackground: false` preference (see `### isBackground Default` above), minimizing background terminal creation.

### Terminal Retry Hygiene

When retrying a failed command that was run in a background terminal (`isBackground: true` / `mode: async`), follow this kill-before-retry protocol:

1. **Record** the terminal ID returned by `run_in_terminal` from the failed attempt
2. **Kill** the failed terminal via `kill_terminal` using that specific terminal ID — load the tool first via `tool_search_tool_regex` if not already loaded
3. **Log and proceed** if `kill_terminal` fails (non-fatal — tool may be unavailable in restricted contexts or version regressions)
4. **Check port** (dev servers only): before restarting a server, run `pwsh -NoProfile -NonInteractive -File .github/scripts/check-port.ps1 -Port {PORT}` to verify the port was released — output is JSON `{"InUse":true/false,"Pid":...,"ProcessName":...}`; if the port is still in use, log the diagnostic and proceed with the retry (non-blocking)
5. **Start** the new attempt in a fresh terminal

**Scope**: This protocol applies to within-step retry loops for `isBackground: true` / `mode: async` terminals that have trackable IDs. Phase-boundary cleanup of accumulated terminals remains governed by `### Terminal Cleanup` above and Code-Conductor's Terminal Lifecycle Protocol.

**Interaction with Terminal Cleanup**: Kill-before-retry and Terminal Cleanup are complementary, non-overlapping. Kill-before-retry acts immediately before a retry within the same step; Terminal Cleanup acts at step boundaries. Neither subsumes the other. If both target the same terminal ID, the first successful kill wins — subsequent attempts are non-fatal no-ops.

**Degradation**: Both `kill_terminal` failures and `check-port.ps1` errors are non-blocking. The protocol degrades gracefully to retry-without-kill when tools are unavailable.
