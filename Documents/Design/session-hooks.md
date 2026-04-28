# Design: Session Hooks

> **Current state — Issue #409**: hook-based delivery returned, but now through plugin-distributed hook files rather than workspace-discovered `.github/hooks/session-cleanup.json`. Claude-format installs use `hooks/hooks.json`; Copilot-format installs use root `hooks.json` because Copilot does not define `${CLAUDE_PLUGIN_ROOT}`. The `session-startup` skill remains the agent-side contract for consuming injected `additionalContext`, preserving the run-once marker `/memories/session/session-startup-check-complete.md`, and keeping manual detector runs available. The plugin-release-hygiene `PostToolUse` hook now ships through the same plugin-distributed architecture. Historical context below is preserved so the earlier hook → instruction → skill eras remain traceable.
>
> Session-state survival for the run-once startup marker is governed by [skills/session-memory-contract/SKILL.md](../../skills/session-memory-contract/SKILL.md) (`SMC-07`); release-hygiene hook state is governed by `SMC-12`.
>
> **v2.0.0 update (agent-orchestra rename)**: The `COPILOT_ORCHESTRA_ROOT` / `WORKFLOW_TEMPLATE_ROOT` env-var surface described in D7, D9, and the setup-requirement text below was removed in v2.0.0. The detector wrapper at `skills/session-startup/scripts/session-cleanup-detector.ps1` now self-resolves its repo root via `$PSScriptRoot`, so no environment variables are required for either plugin-cache or direct-clone installs. Silent-skip still applies when `pwsh` is unavailable or the detector returns non-JSON output.

## Summary

The current design uses plugin-distributed hooks to restore deterministic startup automation across both Claude Code and Copilot. Claude-format installs use `hooks/hooks.json`; Copilot-format installs use root `hooks.json`. Both carry `SessionStart` for stale-state cleanup context injection and `PostToolUse` for plugin-release-hygiene version-bump prompting. The `session-startup` skill remains responsible for run-once semantics, detector-output handling, fail-open behavior, opt-in cleanup, and manual fallback invocation, while the plugin manifests declare the appropriate hook file so installs carry the behavior automatically.

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
| D13 | Hook delivery comeback | Return to hook-based delivery via plugin-distributed `hooks/hooks.json` | Avoids the unreliable workspace-discovered hook mechanism from issue #109 while removing LLM-priority dependence from per-agent trigger text | Plugin hook |
| D14 | Hook declaration path | Declare format-appropriate hook files in each manifest (`hooks/hooks.json` for Claude, `hooks.json` for Copilot) | Keeps hook delivery explicit for both tool formats while accommodating Copilot's missing plugin-root token | Plugin hook |
| D15 | Shared hook file scope | Carry both `SessionStart` and `PostToolUse` in the same hook file | Keeps startup hygiene and release hygiene under one plugin-distributed hook surface and reduces drift between tools | Plugin hook |
| D16 | Release-hygiene hook location | Move `plugin-release-hygiene-hook.ps1` into `skills/plugin-release-hygiene/scripts/` | Co-locates the hook script with its owning skill and removes the old `.claude/settings.json` / `.claude/hooks/` maintainer-only path | Plugin hook |

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
4. The plugin-distributed `SessionStart` hook runs `session-cleanup-detector.ps1` before the agent sees the request and injects any resulting `additionalContext` into the first turn.
5. The `session-startup` skill first looks for the session-memory run-once marker `/memories/session/session-startup-check-complete.md`. If the marker is absent, the first automatic startup check is honored; later agent hops in the same conversation skip that automatic path.
6. The detector evaluates cleanup signals in this order:
   - **Current branch**: detects an upstream-deleted current branch, plus a current `claude/*` no-upstream worktree branch only when its HEAD is reachable from the resolved remote default branch. Current-worktree cleanup commands are narrative inline text outside the fenced block so the auto-run path cannot remove its own checkout.
   - **Tracking files**: detects stale issue-scoped `.copilot-tracking/` files for issues whose remote `feature/issue-*` branch is gone; persistent calibration data is excluded.
   - **Sibling worktrees**: detects sibling worktrees on merged `claude/*` no-upstream branches and sibling `feature/issue-*` branches whose upstream branch was deleted; cleanup commands are inside the fenced block.
   - **Orphan branches**: detects unattached merged `claude/*` no-upstream branches and unattached upstream-deleted `feature/issue-*` branches; cleanup commands are inside the fenced block.
   - **Fail-open behavior**: fetch, worktree-list, for-each-ref, per-candidate merge-base, and ref-lookup failures skip unverifiable candidates without failing the startup flow.
   - **Opt-in cleanup**: the detector reports findings only; cleanup runs only after user confirmation.
7. After that first automatic startup check, the `session-startup` skill records `/memories/session/session-startup-check-complete.md` regardless of whether cleanup will later be accepted, declined, or skipped.
8. The `session-startup` skill surfaces `additionalContext` describing what needs cleanup (branch signal leads when both fire).
9. Agent asks user via `vscode/askQuestions`: context reflects which signal(s) fired and asks whether to run the fenced cleanup block.
10. If confirmed → runs only the fenced commands. These may call `post-merge-cleanup.ps1` for current/tracking-file cleanup or direct `git worktree remove` / `git branch -D` commands for sibling and orphan cleanup.
11. Cleanup remains opt-in. Current-worktree inline commands are manual instructions that must be run from another checkout.

---

## Plugin Distribution Architecture

Hook delivery now ships through the plugin manifests rather than workspace-level `chat.hookFilesLocations` configuration. `.claude-plugin/plugin.json` declares `hooks/hooks.json`, while the root `plugin.json` declares `hooks.json`, so downstream installs receive the startup and release-hygiene hooks automatically in both formats.

The detector wrapper at `skills/session-startup/scripts/session-cleanup-detector.ps1` still self-resolves its repo root via `$PSScriptRoot`, which preserves the v2.0.0 removal of `COPILOT_ORCHESTRA_ROOT` / `WORKFLOW_TEMPLATE_ROOT` as runtime requirements. Manual fallback invocation therefore remains path-stable in both repo-clone and plugin-cache contexts.

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
| `hooks/hooks.json` | Claude-format plugin-distributed hook configuration carrying `SessionStart` and `PostToolUse` | **Active** — introduced in issue #409 |
| `hooks.json` | Copilot-format plugin-distributed hook configuration carrying `SessionStart` and `PostToolUse` via explicit cache-root resolution | **Active** — introduced in issue #409 |
| `skills/session-startup/SKILL.md` | Current agent-side protocol for consuming hook-injected startup context; preserves run-once, fail-open, and manual fallback semantics | Active |
| `skills/session-startup/scripts/session-cleanup-detector.ps1` | Startup cleanup detector for current branches, issue-scoped tracking files, sibling worktrees, and orphan branches; persistent calibration paths are excluded; emits cleanup commands without env-var requirements | Active — updated (issue #185, migrated to skill path in issue #360, expanded for Claude worktrees in issue #452) |
| `skills/session-startup/scripts/post-merge-cleanup.ps1` | Archives tracking files, deletes local/remote branch, syncs default branch | Active — migrated to skill path in issue #360 |
| `skills/plugin-release-hygiene/scripts/plugin-release-hygiene-hook.ps1` | Plugin-distributed `PostToolUse` hook script for entry-point version-bump proposals | **Active** — moved from `.claude/hooks/` in issue #409 |
| `.claude/settings.json` | Former maintainer-local `PostToolUse` hook configuration for release hygiene | **Deleted** — superseded by `hooks/hooks.json` in issue #409 |

---

## Inline-Dispatch Contract

The inline-dispatch contract added for issue #412 and updated by issue #437 enforces the same direct-command pre-flight surface across all three Claude command files: `commands/experience.md`, `commands/design.md`, and `commands/plan.md`. Each command file carries command-side enforcement for session-startup Steps 4, 6, and 7b, the canonical startup option labels, Step 9 paired-body halt-on-fail prose, and provenance-gate labels/prose. `.github/scripts/Tests/inline-dispatch-contract.Tests.ps1` asserts prose presence per command and per step using canonical option labels extracted from the fenced YAML blocks in `skills/session-startup/SKILL.md` and `skills/provenance-gate/SKILL.md`.

| Command file | Enforced here | Deferred elsewhere |
| --- | --- | --- |
| `commands/experience.md` | Steps 4, 6, 7b, 9, provenance-gate | None |
| `commands/design.md` | Steps 4, 6, 7b, 9, provenance-gate | None |
| `commands/plan.md` | Steps 4, 6, 7b, 9, provenance-gate | None for direct `/plan` |

Historical note: issue #412 originally treated direct `/plan` as a carve-out for Step 9 and provenance. Issue #437 removed that carve-out for the command file, so direct `/plan` now matches `/experience` and `/design`. `/orchestrate` and direct Issue-Planner subagent dispatch can still enter through the `issue-planner` shell pending #457.

Cross-tool asymmetry per D6 of #412: Copilot's `.github/prompts/*.prompt.md` files are thin one-line dispatchers without a parent-side prose surface. Copilot inline-dispatch enforcement is owned by the agent body (`agents/{Name}.agent.md`) and is tracked in #414.

---

## Requirements

- Plugin manifests must declare their format-appropriate hook file so installs receive the startup and release-hygiene hooks automatically
- The automatic startup check runs at most once per conversation because the session-memory marker `/memories/session/session-startup-check-complete.md` is checked before the detector run and recorded after the first automatic startup check
- If session-memory read or write fails, the startup flow fails open and still runs the detector rather than suppressing cleanup detection
- Detector git failures fail open: fetch, worktree-list, for-each-ref, per-candidate merge-base, and ref-lookup failures suppress unverifiable candidates without aborting the session
- Explicit manual detector runs remain available after the automatic guard fires
- Linux/macOS without `pwsh`: the hook or manual fallback detects unavailability and skips silently
- If the detector script is missing or the detector returns non-JSON output, the automatic startup check skips silently
