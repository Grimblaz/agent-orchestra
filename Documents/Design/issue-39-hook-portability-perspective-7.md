# Issue #39: Hook Portability via WORKFLOW_TEMPLATE_ROOT + Code-Critic Perspective 7

## Summary

Two small, complementary changes: (1) make the SessionStart hook portable across downstream repos via `WORKFLOW_TEMPLATE_ROOT`, and (2) add Documentation Script Audit as Code-Critic Perspective 7.

## Problem

### Part 1: Hook Portability

The SessionStart hook (`.github/hooks/session-cleanup.json`) is consumed by downstream repos via the VS Code `chat.hookFilesLocations` setting. The hook JSON runs in the downstream workspace, but its `command` called `.github/scripts/session-cleanup-detector.ps1` using a **relative path** — which resolves against the downstream repo's workspace root where the script does not exist.

Similarly, the detector script's output referenced `post-merge-cleanup.ps1` with a relative path that also would not resolve in downstream repos.

### Part 2: Documentation Script Audit Gap

Code-Critic had no checklist step for verifying that shell commands embedded in Markdown documentation are self-consistent. The PR #37 post-PR review found `copilot-instructions.md` quick-validate commands that always self-matched because the file hosting the command was itself inside the searched path.

## Design Decisions

### WORKFLOW_TEMPLATE_ROOT env var approach

**Decision**: Use a `WORKFLOW_TEMPLATE_ROOT` environment variable (set once globally) for all script path resolution.

**Alternatives considered**:
- **Option A — Dynamically resolve from hook file location**: No stable VS Code API for this at hook runtime
- **Option B — Inline all logic in hook JSON**: Brittle, unmaintainable
- **Option C — Symlink/copy on setup**: Requires per-repo setup step, defeats plug-and-play

**Why env var**: Explicit, transparent, works across all repos, no dynamic resolution needed.

**Unset behavior**: Fail with a clear, actionable error message (not silent no-op) — users must be told they need to set the variable.

### Perspective 7 numbering

PR #38 added Perspective 6 (Script & Automation Files) after issue #39 was filed. Documentation Script Audit is therefore Perspective 7.

### Bundling both changes

Both changes are small (5 files, ~60 lines). They share the same portability theme and the same PR review cycle applies to both cleanly.

## Changes

| File | Change |
|------|--------|
| `.github/hooks/session-cleanup.json` | Resolve detector via `$WORKFLOW_TEMPLATE_ROOT`; structured JSON error when unset |
| `.github/scripts/session-cleanup-detector.ps1` | Use `$env:WORKFLOW_TEMPLATE_ROOT` in emitted cleanup command paths; validate path safety |
| `.github/agents/Code-Critic.agent.md` | Add Perspective 7 (Documentation Script Audit); update count 6→7; output format row |
| `.github/copilot-instructions.md` | Fix self-match bug in quick-validate grep chains |
| `.github/architecture-rules.md` | Fix symmetric self-match bug (copilot-instructions.md exclusion) |
| `.github/instructions/post-pr-review.instructions.md` | Update manual fallback cleanup command to use env var path |
| `.github/agents/Code-Conductor.agent.md` | Update Step 0 cleanup note to use env var path |
| `CUSTOMIZATION.md` | Add Section 6 documenting hook setup and WORKFLOW_TEMPLATE_ROOT requirement |

## Acceptance Criteria

- Hook resolves scripts via `WORKFLOW_TEMPLATE_ROOT`; outputs structured JSON error when unset
- All emitted cleanup commands use env var path
- CUSTOMIZATION.md documents setup including VS Code 1.109.3+ requirement
- Code-Critic Perspective 7 added with gate, 3-item checklist, output format row
- Quick-validate grep commands in both `copilot-instructions.md` and `architecture-rules.md` correctly return 0
- No relative `pwsh .github/scripts/` paths remain in any user-facing instruction or agent file
