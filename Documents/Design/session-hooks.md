# Design: Session Hooks

## Summary

The `SessionStart` hook replaces the retired Janitor agent by converting its mechanical post-merge cleanup work into an automated VS Code Copilot hook. The hook fires at the natural "ready for next work" moment — when the user starts a new agent session after merging a PR — and prompts for cleanup with no overhead when nothing needs cleaning. A second enhancement (`WORKFLOW_TEMPLATE_ROOT`) makes the hook portable across downstream repos that consume it via `chat.hookFilesLocations`.

Code-Critic Perspective 7 (Documentation Script Audit) was added in the same phase to close a gap where shell commands embedded in Markdown documentation went unreviewed for self-consistency.

---

## Design Decisions

| # | Decision | Choice | Rationale |
|---|----------|--------|-----------|
| D1 | Cleanup mechanism | VS Code `SessionStart` hook | Fires at the natural post-merge moment; zero overhead for sessions with nothing to clean |
| D2 | Confirmation model | Agent-mediated via `vscode/askQuestions` | `PreToolUse` is the only hook with `permissionDecision: "ask"` but does not fit the trigger pattern; agent-mediated confirmation is functionally equivalent |
| D3 | Janitor retirement | Remove entirely; absorb all capabilities | Mechanical work moved to hook; judgment work absorbed by existing pipeline stages |
| D4 | Implementation language | PowerShell (`.ps1`) | Cross-platform via `pwsh`; supports both parameterized invocation and hook-triggered flow |
| D5 | Issue closure | `Closes #N` in PR body | GitHub auto-close is sufficient — no summary comment needed |
| D6 | Knowledge capture | Dropped | Pipeline already produces durable artifacts (design in issue body, `Documents/Design/` file, PR description); rare novel insights are left as manual developer actions |
| D7 | Hook portability | `WORKFLOW_TEMPLATE_ROOT` env var | Explicit and transparent; works across all repos; no dynamic resolution needed; unset behavior: fail with a clear actionable error, not silent no-op |

---

## Capability Map

| Former Janitor Capability | New Home |
|---|---|
| Archive tracking files | `SessionStart` hook → `post-merge-cleanup.ps1` |
| Delete branches (local + remote) | `post-merge-cleanup.ps1` |
| Switch to main + git pull | `post-merge-cleanup.ps1` |
| Close GitHub issue | `Closes #N` in PR body (automated by Code-Conductor) |
| Summary comment on issue | Dropped (PR description is the durable record) |
| Tech debt issue closure | Code-Conductor adds `Closes #tech-debt-N` to PR body |
| Knowledge capture (ADRs) | Dropped (pipeline artifacts suffice) |
| Remove obsolete files | Already handled by Code-Smith / Refactor-Specialist |

---

## Hook Flow (User Experience)

1. Code-Conductor creates PR with `Closes #N` → session ends
2. User reviews and merges PR on GitHub (issue auto-closes)
3. User starts a new agent session (any agent)
4. `SessionStart` hook fires silently — `session-cleanup-detector.ps1` runs two independent detection paths:
   - **Branch check** (runs first): detects when the current branch has upstream tracking configured but no remote — indicating the branch was merged and remote deleted. Guards against false positives on local-only branches (no upstream = never pushed = skip).
   - **Tracking file check**: detects stale `.copilot-tracking/` files for issues whose remote branch is gone.
5. Hook injects `additionalContext` describing what needs cleanup (branch signal leads when both fire)
6. Agent asks user via `vscode/askQuestions`: context reflects which signal(s) fired — stale remote branch, stale tracking files, or both; message ends with "Clean up?"
7. If confirmed → runs `post-merge-cleanup.ps1`
8. Script archives files, deletes local/remote branch, syncs default branch

---

## WORKFLOW_TEMPLATE_ROOT Portability

The hook is consumed by downstream repos via `chat.hookFilesLocations`. The hook JSON runs in the downstream workspace, but scripts live in the workflow-template repo — a relative path would not resolve.

**Solution**: All script path resolution uses `$WORKFLOW_TEMPLATE_ROOT` (set once at machine level). If the variable is unset, the hook outputs a structured JSON error with a clear, actionable message — not a silent no-op.

**Setup requirement**: Users must set `WORKFLOW_TEMPLATE_ROOT` to the absolute path of their workflow-template clone before the hook will function. Documented in `CUSTOMIZATION.md` Section 6.

---

## Code-Critic Perspective 7: Documentation Script Audit

Added alongside the portability fix to close a gap found in the post-PR review of issue #36: `copilot-instructions.md` quick-validate commands always self-matched because the file hosting the command was inside the searched path.

**Gate**: Only applies to `.md` files that contain shell or PowerShell code blocks.

**Checklist** (3 items):

1. Every runnable command in a code block produces the documented output when run in a clean clone — no stale commands.
2. Grep/Select-String patterns that search `.github/` exclude the file that hosts the command itself (self-match prevention).
3. Numeric counts in documentation (e.g., "must be 0", "must be 13") match the actual state of the repo.

**Numbering**: Perspective 6 (Script & Automation Files) was added in PR #38 between when issue #39 was filed and when it was implemented; Documentation Script Audit is therefore Perspective 7.

---

## Implementation Files

| File | Purpose |
|------|---------|
| `.github/hooks/session-cleanup.json` | `SessionStart` hook configuration; resolves scripts via `$WORKFLOW_TEMPLATE_ROOT`; structured JSON error when unset |
| `.github/scripts/session-cleanup-detector.ps1` | Dual-path detection: branch check + tracking file check; emits cleanup command paths using `$env:WORKFLOW_TEMPLATE_ROOT` |
| `.github/scripts/post-merge-cleanup.ps1` | Archives tracking files, deletes local/remote branch, syncs default branch |

---

## Requirements

- VS Code 1.109.3+ required for the `SessionStart` hook (Preview feature)
- Hook fires every session until cleanup is run — intentional persistent reminder
- Linux/macOS without `pwsh`: hook uses bash fallback (exits cleanly)
- `WORKFLOW_TEMPLATE_ROOT` must be set for hook to function in downstream repos
