# Design: Replace Janitor Agent with SessionStart Hook

**Issue**: #36
**Date**: 2026-03-02
**Status**: Finalized
**Branch**: feature/issue-36-janitor-to-hook

## Summary

Retires the Janitor agent entirely by converting its mechanical cleanup work into a VS Code Copilot `SessionStart` hook and absorbing remaining judgment-based responsibilities into existing pipeline stages.

---

## Problem

The Janitor agent was invoked manually (or by Code-Conductor as a subagent in Step 0) to handle post-merge cleanup: archiving tracking files, deleting branches, closing issues, knowledge capture, and tech debt remediation. Most of this work is mechanical and deterministic — a poor fit for an LLM agent. The remaining judgment work is either already handled by the existing pipeline or rare enough to not warrant a dedicated agent.

---

## Design Decisions

| # | Decision | Choice | Rationale |
|---|----------|--------|-----------|
| D1 | Mechanism | VS Code `SessionStart` hook | Fires at the natural "ready for next work" moment — after the user has merged the PR and starts a new session. Zero overhead for sessions with nothing to clean. |
| D2 | Confirmation model | Agent-mediated via `ask_questions` | `PreToolUse` is the only hook with `permissionDecision: "ask"` but doesn't fit the trigger pattern. Agent-mediated confirmation is functionally equivalent. |
| D3 | Janitor retirement | Remove entirely; absorb all capabilities | See capability map below. |
| D4 | Implementation language | PowerShell (`.ps1`) | Supports both parameterized invocation and hook-triggered flow. Cross-platform via `pwsh`. |
| D5 | Issue closure | `Closes #N` in PR body | GitHub's auto-close mechanism is sufficient — no summary comment needed. |
| D6 | Knowledge capture | Dropped | Pipeline already produces durable artifacts (design in issue body, `Documents/Design/` file, PR description). Rare novel insights are left as manual developer actions. |

---

## Capability Map

| Former Janitor Capability | New Home |
|---|---|
| Archive tracking files | `SessionStart` hook → cleanup script |
| Delete branches (local + remote) | Cleanup script |
| Switch to main + git pull | Cleanup script |
| Close GitHub issue | `Closes #N` in PR body (automated by Code-Conductor) |
| Summary comment on issue | Dropped (PR description is the durable record) |
| Tech debt issue closure | Code-Conductor adds `Closes #tech-debt-N` to PR body |
| Knowledge capture (ADRs) | Dropped (pipeline artifacts suffice) |
| Remove obsolete files | Already handled by Code-Smith / Refactor-Specialist |

---

## Implementation Files

| File | Purpose |
|------|---------|
| `.github/hooks/session-cleanup.json` | `SessionStart` hook configuration |
| `.github/scripts/session-cleanup-detector.ps1` | Fast detection script — no-op if nothing to clean |
| `.github/scripts/post-merge-cleanup.ps1` | Archives tracking files, deletes branches, syncs default branch |

---

## Hook Flow (User Experience)

1. Code-Conductor creates PR with `Closes #N` → session ends
2. User reviews and merges PR on GitHub (issue auto-closes)
3. User starts a new agent session (any agent)
4. `SessionStart` hook fires silently — detects stale `.copilot-tracking/` files from the merged branch
5. Injects `additionalContext`: describes what needs cleanup
6. Agent asks user via `ask_questions`: "Found stale tracking files from issue #N. Clean up?"
7. If confirmed → runs `post-merge-cleanup.ps1`
8. Script archives files, deletes local/remote branch, syncs default branch

---

## Rejected Alternatives

| Alternative | Reason Rejected |
|-------------|----------------|
| `Stop` hook | PR is not merged yet when Code-Conductor finishes |
| `PostToolUse` hook | `matchers` field is ignored; fires for ALL tools |
| Git `post-merge` hook | Not integrated with agent workflow context |

---

## Notes

- VS Code 1.109.3+ required for the `SessionStart` hook (Preview feature)
- Hook fires every session until cleanup is run — intentional persistent reminder
- Linux/macOS without `pwsh`: hook uses bash fallback (exits cleanly without a warning)
- CE Gate: Not applicable — no customer surface
