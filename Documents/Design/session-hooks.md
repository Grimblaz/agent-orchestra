# Design: Session Hooks

> **⚠️ Superseded — Issue #109**: The VS Code `SessionStart` hook was retired due to unreliable firing across different repositories. It has been replaced by `.github/instructions/session-startup.instructions.md`, a shared instruction file that achieves the same behavior through agent self-check at conversation start. The detector and cleanup scripts remain unchanged; two behavioral changes were made: (1) invocation mechanism (hook → instruction), and (2) `WORKFLOW_TEMPLATE_ROOT` unset behavior (hook era: surfaced an actionable error via `additionalContext`; instruction era: silently skips before the script runs). Historical context below is preserved for reference.

## Summary

The `SessionStart` hook replaces the retired Janitor agent by converting its mechanical post-merge cleanup work into an automated VS Code Copilot hook. The hook fires at the natural "ready for next work" moment — when the user starts a new agent session after merging a PR — and prompts for cleanup with no overhead when nothing needs cleaning. A second enhancement (`WORKFLOW_TEMPLATE_ROOT`) makes the hook portable across downstream repos that consume it via `chat.hookFilesLocations`.

Code-Critic Perspective 7 (Documentation Script Audit) was added in the same phase to close a gap where shell commands embedded in Markdown documentation went unreviewed for self-consistency.

---

## Design Decisions

| # | Decision | Choice | Rationale | Era |
|---|----------|--------|-----------|-----|
| D1 | Cleanup mechanism | VS Code `SessionStart` hook | Fires at the natural post-merge moment; zero overhead for sessions with nothing to clean | Hook |
| D2 | Confirmation model | Agent-mediated via `vscode/askQuestions` | `PreToolUse` is the only hook with `permissionDecision: "ask"` but does not fit the trigger pattern; agent-mediated confirmation is functionally equivalent | Hook |
| D3 | Janitor retirement | Remove entirely; absorb all capabilities | Mechanical work moved to hook; judgment work absorbed by existing pipeline stages | Hook |
| D4 | Implementation language | PowerShell (`.ps1`) | Cross-platform via `pwsh`; supports both parameterized invocation and hook-triggered flow | Hook |
| D5 | Issue closure | `Closes #N` in PR body | GitHub auto-close is sufficient — no summary comment needed | Hook |
| D6 | Knowledge capture | Dropped | Pipeline already produces durable artifacts (design in issue body, `Documents/Design/` file, PR description); rare novel insights are left as manual developer actions | Hook |
| D7 | Hook portability | `WORKFLOW_TEMPLATE_ROOT` env var | Explicit and transparent; works across all repos; no dynamic resolution needed; hook-era unset behavior: fail with a clear actionable error, not silent no-op (see D9 for instruction-era behavior) | Hook |
| D8 | Hook retirement | Retire `SessionStart` hook entirely | Hook fires unreliably across different repos (works in some, silently fails in others at the OS/IDE level regardless of configuration); instruction files via `chat.instructionsFilesLocations` are more reliable and simpler to maintain | Instruction |
| D9 | Instruction-based replacement | New `session-startup.instructions.md` shared instruction | Instruction files are loaded unconditionally across all repos; same agent-mediated confirmation model (D2); no VS Code version gate; `WORKFLOW_TEMPLATE_ROOT` still required for script path resolution; **unset behavior: silent-skip** (agent checks at Step 1 before running script — no error surfaced to user) | Instruction |

---

## Capability Map

| Former Janitor Capability | New Home |
|---|---|
| Archive tracking files | `session-startup` instruction → `post-merge-cleanup.ps1` _(as of issue #109; formerly `SessionStart` hook)_ |
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

## Root Env Var Portability

The hook is consumed by downstream repos via `chat.hookFilesLocations`. The hook JSON runs in the downstream workspace, but scripts live in the copilot-orchestra repo — a relative path would not resolve.

**Solution**: All script path resolution uses `$COPILOT_ORCHESTRA_ROOT` (primary) or `$WORKFLOW_TEMPLATE_ROOT` (fallback) (set once at machine level). If neither is set, the detector outputs a structured JSON error with a clear, actionable message — not a silent no-op.

**Setup requirement**: Users must set `COPILOT_ORCHESTRA_ROOT` (or the legacy `WORKFLOW_TEMPLATE_ROOT`) to the absolute path of their copilot-orchestra clone before the startup check will function. Documented in `CUSTOMIZATION.md` Section 6.

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

| File | Purpose | Status |
|------|---------|--------|
| `.github/hooks/session-cleanup.json` | `SessionStart` hook configuration; resolves scripts via `$WORKFLOW_TEMPLATE_ROOT`; structured JSON error when unset | **Deleted** — retired in issue #109 |
| `.github/instructions/session-startup.instructions.md` | Agent self-check instruction; runs detector at conversation start; uses `$env:COPILOT_ORCHESTRA_ROOT` (fallback: `$env:WORKFLOW_TEMPLATE_ROOT`) for script paths | **Reference** — operational content inlined into `.github/copilot-instructions.md` (issue #118) |
| `.github/scripts/session-cleanup-detector.ps1` | Dual-path detection: branch check + tracking file check; emits cleanup command paths using `$env:COPILOT_ORCHESTRA_ROOT` (fallback: `$env:WORKFLOW_TEMPLATE_ROOT`) | Active — updated (issue #130) |
| `.github/scripts/post-merge-cleanup.ps1` | Archives tracking files, deletes local/remote branch, syncs default branch | Active — unchanged |

---

## Requirements

- ~~VS Code 1.109.3+ required for the `SessionStart` hook (Preview feature)~~ — requirement dropped; instruction-based approach works on any VS Code version with Copilot Chat
- Agent prompts at conversation start until cleanup is run — intentional persistent behavior (unchanged from hook design)
- Linux/macOS without `pwsh`: instruction detects unavailability and skips silently
- `COPILOT_ORCHESTRA_ROOT` (or `WORKFLOW_TEMPLATE_ROOT` as fallback) must be set for scripts to function in downstream repos
