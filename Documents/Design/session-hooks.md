# Design: Session Hooks

> **⚠️ Superseded — Issue #109**: The VS Code `SessionStart` hook was retired due to unreliable firing across different repositories. It was first replaced by `.github/instructions/session-startup.instructions.md`, and is now delivered by the `session-startup` skill with a per-agent self-check trigger in the four pipeline-entry agent files at conversation start. The cleanup script remained unchanged, but later detector work added a session-memory run-once guard using `/memories/session/session-startup-check-complete.md`, updated the detector to treat persistent calibration data as non-cleanup state, preserved explicit manual detector runs, and moved the per-agent trigger stub from `## Process` to the first content line after each pipeline-entry agent's role description so the startup check has higher positional priority under context pressure. Another behavioral change is `WORKFLOW_TEMPLATE_ROOT` unset behavior (hook era: surfaced an actionable error via `additionalContext`; instruction/skill era: silently skips before the script runs). Historical context below is preserved for reference.

## Summary

The `SessionStart` hook replaces the retired Janitor agent by converting its mechanical post-merge cleanup work into an automated VS Code Copilot hook. The hook fires at the natural "ready for next work" moment — when the user starts a new agent session after merging a PR — and prompts for cleanup with no overhead when nothing needs cleaning. A second enhancement (`WORKFLOW_TEMPLATE_ROOT`) makes the hook portable across downstream repos that consume it via `chat.hookFilesLocations`.

Code-Critic Perspective 7 (Documentation Script Audit) was added in the same phase to close a gap where shell commands embedded in Markdown documentation went unreviewed for self-consistency. _(Merged into §6 Script & Automation as doc-audit sub-gate in issue #212.)_

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
| D9 | Instruction/skill replacement | First `session-startup.instructions.md`, now the `session-startup` skill with a per-agent trigger stub on the first content line after the role description in each pipeline-entry agent file | Delivery moved from an always-loaded shared instruction to a plugin-distributable skill while preserving the same agent-mediated confirmation model (D2), no VS Code version gate, and the same `WORKFLOW_TEMPLATE_ROOT`-based silent-skip behavior before the script runs | Instruction → Skill |
| D10 | Automatic run-once behavior | Session-memory marker `/memories/session/session-startup-check-complete.md` checked before the automatic detector run and recorded after the first automatic startup check | Prevents repeated prompts across later agent hops in the same conversation while keeping the detector script stateless and manual reruns available | Instruction |
| D11 | Calibration cleanup noise | Treat `.copilot-tracking/calibration/**` as persistent data, not cleanup work | Avoids false-positive cleanup prompts for repo-scoped calibration state | Instruction |
| D12 | Trigger placement within agent files | Put the `session-startup` trigger on the first content line after the role description in each pipeline-entry agent and remove the redundant silent-skip summary from `## Process` | Reduces instruction competition in crowded `## Process` sections, especially for Experience-Owner, while keeping silent-skip and run-once semantics owned by the skill contract and wording test | Skill |

---

## Capability Map

| Former Janitor Capability | New Home |
|---|---|
| Archive tracking files | `session-startup` skill → `post-merge-cleanup.ps1` _(as of issue #345; formerly `session-startup` instruction, and before that the `SessionStart` hook)_ |
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
4. The current startup check first looks for the session-memory run-once marker `/memories/session/session-startup-check-complete.md`. If the marker is absent, the first automatic startup check runs `session-cleanup-detector.ps1`; later agent hops in the same conversation skip that automatic run.
5. The detector evaluates two independent detection paths:
   - **Branch check** (runs first): detects when the current branch has upstream tracking configured but no remote — indicating the branch was merged and remote deleted. Guards against false positives on local-only branches (no upstream = never pushed = skip).
   - **Tracking file check**: detects stale issue-scoped `.copilot-tracking/` files for issues whose remote branch is gone; persistent calibration data is excluded.
6. After that first automatic startup check, the `session-startup` skill records `/memories/session/session-startup-check-complete.md` regardless of whether cleanup will later be accepted, declined, or skipped.
7. The `session-startup` skill surfaces `additionalContext` describing what needs cleanup (branch signal leads when both fire).
8. Agent asks user via `vscode/askQuestions`: context reflects which signal(s) fired — stale remote branch, stale tracking files, or both; message ends with "Clean up?"
9. If confirmed → runs `post-merge-cleanup.ps1`
10. Script archives files, deletes local/remote branch, syncs default branch

---

## Root Env Var Portability

The hook is consumed by downstream repos via `chat.hookFilesLocations`. The hook JSON runs in the downstream workspace, but scripts live in the copilot-orchestra repo — a relative path would not resolve.

**Solution**: All script path resolution uses `$COPILOT_ORCHESTRA_ROOT` (primary) or `$WORKFLOW_TEMPLATE_ROOT` (fallback) (set once at machine level). In the instruction era, if neither is set, the startup check silently skips before the detector runs. Session-memory access failures are different: the automatic guard fails open and still runs the detector.

**Setup requirement**: Users must set `COPILOT_ORCHESTRA_ROOT` (or the legacy `WORKFLOW_TEMPLATE_ROOT`) to the absolute path of their copilot-orchestra clone before the startup check will function. Documented in `CUSTOMIZATION.md` Section 6.

---

## Code-Critic Perspective 7: Documentation Script Audit _(merged into §6 in #212)_

Added alongside the portability fix to close a gap found in the post-PR review of issue #36: `copilot-instructions.md` quick-validate commands always self-matched because the file hosting the command was inside the searched path.

**Gate**: Only applies to `.md` files that contain shell or PowerShell code blocks.

**Checklist** (3 items):

1. Every runnable command in a code block produces the documented output when run in a clean clone — no stale commands.
2. Grep/Select-String patterns that search `.github/` exclude the file that hosts the command itself (self-match prevention).
3. Numeric counts in documentation (e.g., "must be 0", "must be 13") match the actual state of the repo.

**Numbering**: Perspective 6 (Script & Automation Files) was added in PR #38 between when issue #39 was filed and when it was implemented; Documentation Script Audit is therefore Perspective 7. _(Both merged into a single §6 Script & Automation perspective with branching gate in issue #212; total perspective count reduced from 7 to 6.)_

---

## Implementation Files

| File | Purpose | Status |
|------|---------|--------|
| `.github/hooks/session-cleanup.json` | `SessionStart` hook configuration; resolves scripts via `$WORKFLOW_TEMPLATE_ROOT`; structured JSON error when unset | **Deleted** — retired in issue #109 |
| `.github/instructions/session-startup.instructions.md` | Historical intermediate delivery vehicle between the retired hook and the current skill; checked the session-memory run-once marker `/memories/session/session-startup-check-complete.md` before the automatic detector run, recorded the marker after the first automatic startup check, and used `$env:COPILOT_ORCHESTRA_ROOT` (fallback: `$env:WORKFLOW_TEMPLATE_ROOT`) for script paths | **Historical** — superseded by `.github/skills/session-startup/SKILL.md` (issue #345) |
| `.github/skills/session-startup/SKILL.md` | Current detailed protocol for the startup self-check; preserves the run-once marker, fail-open behavior, and detector/script path rules while the trigger stub lives in the four pipeline-entry agent files | Active |
| `.github/skills/session-startup/scripts/session-cleanup-detector.ps1` | Dual-path detection: branch check + issue-scoped tracking file check; persistent calibration paths are excluded; emits cleanup command paths using `$env:COPILOT_ORCHESTRA_ROOT` (fallback: `$env:WORKFLOW_TEMPLATE_ROOT`) | Active — updated (issue #185, migrated to skill path in issue #360) |
| `.github/skills/session-startup/scripts/post-merge-cleanup.ps1` | Archives tracking files, deletes local/remote branch, syncs default branch | Active — migrated to skill path in issue #360 |

---

## Requirements

- ~~VS Code 1.109.3+ required for the `SessionStart` hook (Preview feature)~~ — requirement dropped; instruction-based approach works on any VS Code version with Copilot Chat
- The automatic startup check runs at most once per conversation because the session-memory marker `/memories/session/session-startup-check-complete.md` is checked before the detector run and recorded after the first automatic startup check
- If session-memory read or write fails, the startup flow fails open and still runs the detector rather than suppressing cleanup detection
- Explicit manual detector runs remain available after the automatic guard fires
- Linux/macOS without `pwsh`: instruction detects unavailability and skips silently
- If the root environment variables are unset, the detector script is missing, or the detector returns non-JSON output, the automatic startup check skips silently
- `COPILOT_ORCHESTRA_ROOT` (or `WORKFLOW_TEMPLATE_ROOT` as fallback) must be set for scripts to function in downstream repos
